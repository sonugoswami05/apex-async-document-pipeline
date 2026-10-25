@IsTest
private class DocumentClassificationBatchTest {
    private static final Integer RECORD_COUNT = 5;

    @TestSetup
    static void setup() {
        User pipelineUser = TestDataFactory.createPipelineUser();
        System.runAs(pipelineUser) {
            Application__c application = TestDataFactory.createApplication('Batch test application');
            TestDataFactory.createChecklist(application.Id, new List<String>{ 'Bank Statement', 'Photo ID' });
            Id fileId = TestDataFactory.createFile('statement', 2048);
            TestDataFactory.createIntakes(application.Id, fileId, RECORD_COUNT);
        }
    }

    private static List<Document_Intake__c> queuedScope() {
        return [
            SELECT Id, Name, Application__c, Attempt_Count__c, Content_Document_Id__c, File_Name__c
            FROM Document_Intake__c
            WHERE Status__c = :IntakeStatus.QUEUED
            ORDER BY CreatedDate, Id
        ];
    }

    private static Integer countLocator(Database.QueryLocator locator) {
        Integer count = 0;
        Database.QueryLocatorIterator iterator = locator.iterator();
        while (iterator.hasNext()) {
            iterator.next();
            count++;
        }
        return count;
    }

    @IsTest
    static void scopeSizeFollowsCalloutLimits() {
        Assert.areEqual(5, DocumentClassificationBatch.SCOPE_SIZE, 'floor(120 s / (1 x 20 s)) - 1 = 5');
        Integer worstCaseSeconds = DocumentClassificationBatch.SCOPE_SIZE
            * DocumentClassificationBatch.CALLOUTS_PER_RECORD
            * (DocumentClassifierService.TIMEOUT_MS / 1000);
        Assert.isTrue(worstCaseSeconds < 120, 'Worst-case callout time must stay under 120 s');
        Assert.isTrue(
            DocumentClassificationBatch.SCOPE_SIZE * DocumentClassificationBatch.CALLOUTS_PER_RECORD <= Limits.getLimitCallouts(),
            'Callouts per chunk must stay under the callout limit'
        );
    }

    @IsTest
    static void startSelectsFirstAttemptsAndStaleRetriesOnly() {
        System.runAs(TestDataFactory.pipelineUser()) {
            List<Document_Intake__c> intakes = queuedScope();
            // A retry the retry chain still owns: not picked up.
            intakes[0].Attempt_Count__c = 1;
            intakes[0].Next_Attempt_At__c = Datetime.now().addMinutes(2);
            // A retry whose chain died 2 hours ago: picked up.
            intakes[1].Attempt_Count__c = 2;
            intakes[1].Next_Attempt_At__c = Datetime.now().addHours(-2);
            // Still uploading: not picked up.
            intakes[2].Status__c = IntakeStatus.UPLOADING;
            intakes[2].Content_Document_Id__c = null;
            update intakes;

            Test.startTest();
            Integer selected = countLocator(new DocumentClassificationBatch().start(null));
            Test.stopTest();

            Assert.areEqual(3, selected, 'Two fresh records plus one stale retry');
        }
    }

    @IsTest
    static void startHandlesTwoHundredRecords() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Application__c application = [SELECT Id FROM Application__c LIMIT 1];
            Id fileId = Id.valueOf([SELECT Content_Document_Id__c FROM Document_Intake__c LIMIT 1].Content_Document_Id__c);
            TestDataFactory.createIntakes(application.Id, fileId, 200);

            Test.startTest();
            Integer selected = countLocator(new DocumentClassificationBatch().start(null));
            Test.stopTest();

            Assert.areEqual(200 + RECORD_COUNT, selected, 'Every queued first attempt is selected');
        }
    }

    @IsTest
    static void executeClassifiesAndQueuesAllocation() {
        System.runAs(TestDataFactory.pipelineUser()) {
            AsyncJobs.captureOnly = true;
            Test.setMock(HttpCalloutMock.class, ClassifierHttpMock.success('Bank Statement', 0.95));
            DocumentClassificationBatch batch = new DocumentClassificationBatch();

            Test.startTest();
            batch.execute(null, queuedScope());
            batch.finish(null);
            Test.stopTest();

            for (Document_Intake__c intake : TestDataFactory.reload(TestDataFactory.idsOf(queuedScopeAll()))) {
                Assert.areEqual(IntakeStatus.CLASSIFYING, intake.Status__c, 'Waiting for allocation');
                Assert.areEqual('Bank Statement', intake.Suggested_Type__c, 'Suggested type saved');
                Assert.areEqual(95, intake.Confidence__c.intValue(), 'Confidence saved as a percent');
                Assert.areEqual(1, intake.Attempt_Count__c.intValue(), 'One attempt recorded');
            }
            Assert.areEqual(1, AsyncJobs.captured.size(), 'One allocation job, no retry job');
            Assert.isInstanceOfType(AsyncJobs.captured[0], DocumentAllocationQueueable.class, 'Allocation is queued');
            Assert.areEqual(RECORD_COUNT, ((DocumentAllocationQueueable) AsyncJobs.captured[0]).intakeIds.size(), 'All ids handed over');
            Assert.areEqual(RECORD_COUNT, batch.classified, 'Stateful counter updated');
            Assert.isTrue(batch.summary().contains(RECORD_COUNT + ' classified'), 'Summary reports the run');
        }
    }

    @IsTest
    static void serverErrorSchedulesRetryWithBackoff() {
        System.runAs(TestDataFactory.pipelineUser()) {
            TestDataFactory.useSettings(80, 4, 1);
            AsyncJobs.captureOnly = true;
            Test.setMock(HttpCalloutMock.class, ClassifierHttpMock.status(500, 'upstream down'));
            DocumentClassificationBatch batch = new DocumentClassificationBatch();
            Datetime before = Datetime.now();

            Test.startTest();
            batch.execute(null, queuedScope());
            batch.finish(null);
            Test.stopTest();

            for (Document_Intake__c intake : TestDataFactory.reload(batch.retryIds)) {
                Assert.areEqual(IntakeStatus.QUEUED, intake.Status__c, 'Stays queued for retry');
                Assert.areEqual(1, intake.Attempt_Count__c.intValue(), 'First attempt counted');
                Assert.isTrue(intake.Next_Attempt_At__c > before, 'Retry time is in the future');
                Assert.isTrue(intake.Last_Error__c.contains('[Attempt 1'), 'Error records the attempt');
                Assert.isTrue(intake.Last_Error__c.contains('HTTP 500'), 'Error records the cause');
            }
            Assert.areEqual(RECORD_COUNT, batch.retryIds.size(), 'All records scheduled for retry');
            Assert.areEqual(1, AsyncJobs.captured.size(), 'Only the retry job, nothing to allocate');
            Assert.isInstanceOfType(AsyncJobs.captured[0], DocumentRetryQueueable.class, 'Retry job queued');
            Assert.areEqual(1, AsyncJobs.capturedDelays[0], 'First retry waits the base backoff');
        }
    }

    @IsTest
    static void timeoutSchedulesRetry() {
        System.runAs(TestDataFactory.pipelineUser()) {
            AsyncJobs.captureOnly = true;
            Test.setMock(HttpCalloutMock.class, ClassifierHttpMock.timeout());
            DocumentClassificationBatch batch = new DocumentClassificationBatch();

            Test.startTest();
            batch.execute(null, queuedScope());
            Test.stopTest();

            Document_Intake__c intake = TestDataFactory.reload(batch.retryIds)[0];
            Assert.isTrue(intake.Last_Error__c.contains('ClassifierTimeoutException'), 'Timeout type recorded');
            Assert.areEqual(RECORD_COUNT, batch.retryIds.size(), 'Timeouts are retried');
        }
    }

    @IsTest
    static void clientErrorFailsWithoutRetry() {
        System.runAs(TestDataFactory.pipelineUser()) {
            AsyncJobs.captureOnly = true;
            Test.setMock(HttpCalloutMock.class, ClassifierHttpMock.status(400, 'unsupported'));
            DocumentClassificationBatch batch = new DocumentClassificationBatch();
            Set<Id> ids = TestDataFactory.idsOf(queuedScope());

            Test.startTest();
            batch.execute(null, queuedScope());
            batch.finish(null);
            Test.stopTest();

            for (Document_Intake__c intake : TestDataFactory.reload(ids)) {
                Assert.areEqual(IntakeStatus.FAILED, intake.Status__c, 'HTTP 400 fails straight away');
                Assert.isNull(intake.Next_Attempt_At__c, 'No retry scheduled');
            }
            Assert.areEqual(RECORD_COUNT, batch.failed, 'Failures counted');
            Assert.isTrue(AsyncJobs.captured.isEmpty(), 'Nothing to allocate or retry');
        }
    }

    @IsTest
    static void lastAllowedAttemptFailsPermanently() {
        System.runAs(TestDataFactory.pipelineUser()) {
            TestDataFactory.useSettings(80, 1, 1);
            AsyncJobs.captureOnly = true;
            Test.setMock(HttpCalloutMock.class, ClassifierHttpMock.status(503, 'busy'));
            DocumentClassificationBatch batch = new DocumentClassificationBatch();
            Set<Id> ids = TestDataFactory.idsOf(queuedScope());

            Test.startTest();
            batch.execute(null, queuedScope());
            Test.stopTest();

            for (Document_Intake__c intake : TestDataFactory.reload(ids)) {
                Assert.areEqual(IntakeStatus.FAILED, intake.Status__c, 'No attempts left');
                Assert.isTrue(intake.Last_Error__c.contains('HTTP 503'), 'Last error kept');
            }
        }
    }

    @IsTest
    static void missingFileFails() {
        System.runAs(TestDataFactory.pipelineUser()) {
            List<Document_Intake__c> intakes = queuedScope();
            for (Document_Intake__c intake : intakes) {
                intake.Content_Document_Id__c = 'not-an-id';
            }
            update intakes;
            ClassifierHttpMock mock = ClassifierHttpMock.success('Bank Statement', 0.95);
            Test.setMock(HttpCalloutMock.class, mock);
            AsyncJobs.captureOnly = true;

            Test.startTest();
            new DocumentClassificationBatch().execute(null, queuedScope());
            Test.stopTest();

            for (Document_Intake__c intake : TestDataFactory.reload(TestDataFactory.idsOf(intakes))) {
                Assert.areEqual(IntakeStatus.FAILED, intake.Status__c, 'A missing file cannot be retried into existence');
                Assert.isTrue(intake.Last_Error__c.contains('was not found'), 'Reason recorded');
            }
            Assert.areEqual(0, mock.calls, 'No callout without a file');
        }
    }

    @IsTest
    static void oversizedFileGoesToReview() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Id bigFileId = TestDataFactory.createFile('large-scan', DocumentClassificationProcessor.MAX_FILE_BYTES + 1);
            List<Document_Intake__c> intakes = queuedScope();
            intakes[0].Content_Document_Id__c = bigFileId;
            update intakes[0];
            Test.setMock(HttpCalloutMock.class, ClassifierHttpMock.success('Bank Statement', 0.95));
            AsyncJobs.captureOnly = true;
            DocumentClassificationBatch batch = new DocumentClassificationBatch();

            Test.startTest();
            batch.execute(null, new List<Document_Intake__c>{ queuedScope()[0] });
            Test.stopTest();

            Document_Intake__c intake = TestDataFactory.reload(new Set<Id>{ intakes[0].Id })[0];
            Assert.areEqual(IntakeStatus.NEEDS_REVIEW, intake.Status__c, 'Large files go to a person');
            Assert.isTrue(intake.Review_Reason__c.contains('KB'), 'Reason names the size');
            Assert.areEqual(1, batch.sentToReview, 'Counted as sent to review');
        }
    }

    @IsTest
    static void recordDeletedMidRunIsReportedNotDropped() {
        System.runAs(TestDataFactory.pipelineUser()) {
            List<Document_Intake__c> scope = queuedScope();
            delete [SELECT Id FROM Document_Intake__c WHERE Id = :scope[0].Id];
            Test.setMock(HttpCalloutMock.class, ClassifierHttpMock.success('Bank Statement', 0.95));
            AsyncJobs.captureOnly = true;
            DocumentClassificationBatch batch = new DocumentClassificationBatch();

            Test.startTest();
            batch.execute(null, scope);
            Test.stopTest();

            Assert.areEqual(1, batch.saveErrors, 'The failed save is counted');
            Assert.areEqual(RECORD_COUNT - 1, batch.classified, 'The other records still go through');
            Assert.isTrue(batch.summary().contains('1 save errors'), 'Summary reports it');
        }
    }

    @IsTest
    static void endToEndRunLeavesNothingQueued() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Test.setMock(HttpCalloutMock.class, ClassifierHttpMock.success('Bank Statement', 0.95));

            Test.startTest();
            Id jobId = DocumentClassificationBatch.run();
            Test.stopTest();

            Assert.isNotNull(jobId, 'Batch started');
            for (Document_Intake__c intake : [SELECT Status__c FROM Document_Intake__c LIMIT 1000]) {
                Assert.isTrue(
                    intake.Status__c == IntakeStatus.CLASSIFYING || intake.Status__c == IntakeStatus.ALLOCATED,
                    'Every record moved past Queued, got ' + intake.Status__c
                );
            }
        }
    }

    @IsTest
    static void schedulerStartsTheBatch() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Test.setMock(HttpCalloutMock.class, ClassifierHttpMock.success('Bank Statement', 0.95));

            Test.startTest();
            new DocumentClassificationScheduler().execute(null);
            Test.stopTest();

            Assert.areEqual(
                1,
                [SELECT COUNT() FROM AsyncApexJob WHERE JobType = 'BatchApex' AND ApexClass.Name = 'DocumentClassificationBatch'],
                'Scheduler starts one batch'
            );
        }
    }

    private static List<Document_Intake__c> queuedScopeAll() {
        return [SELECT Id FROM Document_Intake__c LIMIT 1000];
    }
}
