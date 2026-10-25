@IsTest
private class DocumentRetryQueueableTest {
    @TestSetup
    static void setup() {
        User pipelineUser = TestDataFactory.createPipelineUser();
        System.runAs(pipelineUser) {
            Application__c application = TestDataFactory.createApplication('Retry test application');
            TestDataFactory.createChecklist(application.Id, new List<String>{ 'Bank Statement' });
            Id fileId = TestDataFactory.createFile('statement', 2048);
            TestDataFactory.createIntakes(application.Id, fileId, 5);
        }
    }

    /** Puts every intake in the "waiting for retry" state. */
    private static Set<Id> markWaiting(Integer attemptsMade, Datetime nextAttemptAt) {
        List<Document_Intake__c> intakes = [SELECT Id FROM Document_Intake__c LIMIT 1000];
        for (Document_Intake__c intake : intakes) {
            intake.Status__c = IntakeStatus.QUEUED;
            intake.Attempt_Count__c = attemptsMade;
            intake.Next_Attempt_At__c = nextAttemptAt;
        }
        update intakes;
        return TestDataFactory.idsOf(intakes);
    }

    @IsTest
    static void repeatedFailureBacksOffExponentially() {
        System.runAs(TestDataFactory.pipelineUser()) {
            TestDataFactory.useSettings(80, 4, 1);
            Set<Id> ids = markWaiting(1, Datetime.now().addMinutes(-1));
            AsyncJobs.captureOnly = true;
            Test.setMock(HttpCalloutMock.class, ClassifierHttpMock.status(502, 'bad gateway'));

            Test.startTest();
            new DocumentRetryQueueable(ids).execute(null);
            Test.stopTest();

            for (Document_Intake__c intake : TestDataFactory.reload(ids)) {
                Assert.areEqual(IntakeStatus.QUEUED, intake.Status__c, 'Still waiting');
                Assert.areEqual(2, intake.Attempt_Count__c.intValue(), 'Second attempt counted');
                Assert.isTrue(intake.Last_Error__c.contains('[Attempt 2'), 'Latest attempt recorded');
            }
            Assert.areEqual(1, AsyncJobs.captured.size(), 'Chain continues');
            Assert.areEqual(2, AsyncJobs.capturedDelays[0], 'Second retry waits 2 x base');
            Assert.areEqual(5, ((DocumentRetryQueueable) AsyncJobs.captured[0]).intakeIds.size(), 'All still tracked');
        }
    }

    @IsTest
    static void finalAttemptMarksFailedAndEndsChain() {
        System.runAs(TestDataFactory.pipelineUser()) {
            TestDataFactory.useSettings(80, 4, 1);
            Set<Id> ids = markWaiting(3, Datetime.now().addMinutes(-1));
            AsyncJobs.captureOnly = true;
            Test.setMock(HttpCalloutMock.class, ClassifierHttpMock.timeout());

            Test.startTest();
            new DocumentRetryQueueable(ids).execute(null);
            Test.stopTest();

            for (Document_Intake__c intake : TestDataFactory.reload(ids)) {
                Assert.areEqual(IntakeStatus.FAILED, intake.Status__c, 'Out of attempts');
                Assert.areEqual(4, intake.Attempt_Count__c.intValue(), 'All four attempts counted');
                Assert.isTrue(intake.Last_Error__c.contains('[Attempt 4'), 'Final error kept on the record');
            }
            Assert.isTrue(AsyncJobs.captured.isEmpty(), 'Chain ends when nothing is waiting');
        }
    }

    @IsTest
    static void successfulRetryAllocatesInline() {
        System.runAs(TestDataFactory.pipelineUser()) {
            TestDataFactory.useSettings(80, 4, 1);
            Set<Id> ids = markWaiting(1, Datetime.now().addMinutes(-1));
            AsyncJobs.captureOnly = true;
            Test.setMock(HttpCalloutMock.class, ClassifierHttpMock.success('Bank Statement', 0.97));

            Test.startTest();
            new DocumentRetryQueueable(ids).execute(null);
            Test.stopTest();

            Checklist_Item__c item = [SELECT Id, Status__c FROM Checklist_Item__c LIMIT 1];
            for (Document_Intake__c intake : TestDataFactory.reload(ids)) {
                Assert.areEqual(IntakeStatus.ALLOCATED, intake.Status__c, 'Allocated in the same job');
                Assert.areEqual(item.Id, intake.Checklist_Item__c, 'Linked to the checklist item');
            }
            Assert.areEqual(IntakeStatus.ITEM_RECEIVED, item.Status__c, 'Checklist item received');
            Assert.isTrue(AsyncJobs.captured.isEmpty(), 'Nothing left to retry');
        }
    }

    @IsTest
    static void notYetDueRecordsAreRescheduledNotCalled() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Set<Id> ids = markWaiting(1, Datetime.now().addMinutes(5));
            AsyncJobs.captureOnly = true;
            ClassifierHttpMock mock = ClassifierHttpMock.success('Bank Statement', 0.97);
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            new DocumentRetryQueueable(ids).execute(null);
            Test.stopTest();

            Assert.areEqual(0, mock.calls, 'Too early, no callout');
            Assert.areEqual(1, AsyncJobs.captured.size(), 'Woken again later');
            Assert.areEqual(5, AsyncJobs.capturedDelays[0], 'Delay matches the earliest retry time');
        }
    }

    @IsTest
    static void moreDueThanOneScopeContinuesImmediately() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Application__c application = [SELECT Id FROM Application__c LIMIT 1];
            Id fileId = Id.valueOf([SELECT Content_Document_Id__c FROM Document_Intake__c LIMIT 1].Content_Document_Id__c);
            TestDataFactory.createIntakes(application.Id, fileId, 3);
            Set<Id> ids = markWaiting(1, Datetime.now().addMinutes(-1));
            AsyncJobs.captureOnly = true;
            Test.setMock(HttpCalloutMock.class, ClassifierHttpMock.success('Bank Statement', 0.97));

            Test.startTest();
            new DocumentRetryQueueable(ids).execute(null);
            Test.stopTest();

            Integer stillWaiting = [SELECT COUNT() FROM Document_Intake__c WHERE Status__c = :IntakeStatus.QUEUED];
            Assert.areEqual(8 - DocumentClassificationBatch.SCOPE_SIZE, stillWaiting, 'One scope per run');
            Assert.areEqual(0, AsyncJobs.capturedDelays[0], 'Remaining due records continue right away');
        }
    }

    @IsTest
    static void recordsMovedOnByAUserAreIgnored() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Set<Id> ids = markWaiting(1, Datetime.now().addMinutes(-1));
            List<Document_Intake__c> intakes = [SELECT Id FROM Document_Intake__c LIMIT 1000];
            for (Document_Intake__c intake : intakes) {
                intake.Status__c = IntakeStatus.NEEDS_REVIEW;
            }
            update intakes;
            AsyncJobs.captureOnly = true;
            ClassifierHttpMock mock = ClassifierHttpMock.success('Bank Statement', 0.97);
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            new DocumentRetryQueueable(ids).execute(null);
            Test.stopTest();

            Assert.areEqual(0, mock.calls, 'Nothing to retry');
            Assert.isTrue(AsyncJobs.captured.isEmpty(), 'Chain ends');
            Assert.isNull(DocumentRetryQueueable.enqueueFor(null), 'Null input is a no-op');
        }
    }

    @IsTest
    static void minutesUntilRoundsUpAndCaps() {
        Assert.areEqual(0, DocumentRetryQueueable.minutesUntil(null), 'No time means now');
        Assert.areEqual(0, DocumentRetryQueueable.minutesUntil(Datetime.now().addMinutes(-3)), 'Past means now');
        Assert.areEqual(3, DocumentRetryQueueable.minutesUntil(Datetime.now().addSeconds(150)), 'Rounds up');
        Assert.areEqual(10, DocumentRetryQueueable.minutesUntil(Datetime.now().addHours(2)), 'Capped at the platform maximum');
    }
}
