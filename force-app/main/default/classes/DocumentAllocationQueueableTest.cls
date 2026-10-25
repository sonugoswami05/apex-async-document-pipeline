@IsTest
private class DocumentAllocationQueueableTest {
    @TestSetup
    static void setup() {
        User pipelineUser = TestDataFactory.createPipelineUser();
        System.runAs(pipelineUser) {
            Application__c application = TestDataFactory.createApplication('Allocation test application');
            TestDataFactory.createChecklist(application.Id, new List<String>{ 'Bank Statement', 'Photo ID' });
        }
    }

    private static Application__c application() {
        return [SELECT Id FROM Application__c LIMIT 1];
    }

    private static Checklist_Item__c item(String documentType) {
        return [SELECT Id, Status__c FROM Checklist_Item__c WHERE Required_Document_Type__c = :documentType LIMIT 1];
    }

    @IsTest
    static void confidentMatchIsAllocated() {
        System.runAs(TestDataFactory.pipelineUser()) {
            TestDataFactory.useSettings(80, 4, 1);
            Set<Id> ids = TestDataFactory.idsOf(
                TestDataFactory.createClassifiedIntakes(application().Id, 3, TestDataFactory.classified('Bank Statement', 92))
            );

            Test.startTest();
            System.enqueueJob(new DocumentAllocationQueueable(ids));
            Test.stopTest();

            Checklist_Item__c bankItem = item('Bank Statement');
            for (Document_Intake__c intake : TestDataFactory.reload(ids)) {
                Assert.areEqual(IntakeStatus.ALLOCATED, intake.Status__c, 'Allocated');
                Assert.areEqual(bankItem.Id, intake.Checklist_Item__c, 'Linked to the matching item');
                Assert.areEqual('Bank Statement', intake.Confirmed_Type__c, 'Confirmed type set');
            }
            Assert.areEqual(IntakeStatus.ITEM_RECEIVED, bankItem.Status__c, 'Item received');
            Assert.areEqual(IntakeStatus.ITEM_OPEN, item('Photo ID').Status__c, 'Other items untouched');
        }
    }

    @IsTest
    static void lowConfidenceGoesToReview() {
        System.runAs(TestDataFactory.pipelineUser()) {
            TestDataFactory.useSettings(80, 4, 1);
            Set<Id> ids = TestDataFactory.idsOf(
                TestDataFactory.createClassifiedIntakes(application().Id, 2, TestDataFactory.classified('Bank Statement', 61.5))
            );

            Test.startTest();
            DocumentAllocationService.Summary summary = DocumentAllocationService.allocate(ids);
            Test.stopTest();

            Assert.areEqual(2, summary.needsReview, 'Both need review');
            for (Document_Intake__c intake : TestDataFactory.reload(ids)) {
                Assert.areEqual(IntakeStatus.NEEDS_REVIEW, intake.Status__c, 'Below threshold');
                Assert.areEqual('Confidence 61.5% is below the 80.0% threshold.', intake.Review_Reason__c, 'Reason is readable');
                Assert.isNull(intake.Checklist_Item__c, 'Not allocated');
            }
            Assert.areEqual(IntakeStatus.ITEM_OPEN, item('Bank Statement').Status__c, 'Item still open');
        }
    }

    @IsTest
    static void thresholdIsInclusive() {
        System.runAs(TestDataFactory.pipelineUser()) {
            TestDataFactory.useSettings(80, 4, 1);
            Set<Id> ids = TestDataFactory.idsOf(
                TestDataFactory.createClassifiedIntakes(application().Id, 1, TestDataFactory.classified('Photo ID', 80))
            );
            Test.startTest();
            DocumentAllocationService.Summary summary = DocumentAllocationService.allocate(ids);
            Test.stopTest();
            Assert.areEqual(1, summary.allocated, 'Exactly at the threshold is allocated');
        }
    }

    @IsTest
    static void typeWithoutOpenItemGoesToReview() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Set<Id> ids = TestDataFactory.idsOf(
                TestDataFactory.createClassifiedIntakes(application().Id, 1, TestDataFactory.classified('Utility Bill', 99))
            );
            Test.startTest();
            DocumentAllocationService.allocate(ids);
            Test.stopTest();

            Document_Intake__c intake = TestDataFactory.reload(ids)[0];
            Assert.areEqual(IntakeStatus.NEEDS_REVIEW, intake.Status__c, 'No item to put it in');
            Assert.isTrue(intake.Review_Reason__c.contains('No open checklist item'), 'Reason given');
        }
    }

    @IsTest
    static void documentWithoutApplicationGoesToReview() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Set<Id> ids = TestDataFactory.idsOf(TestDataFactory.createClassifiedIntakes(null, 1, TestDataFactory.classified('Bank Statement', 99)));
            Test.startTest();
            DocumentAllocationService.allocate(ids);
            Test.stopTest();
            Assert.isTrue(
                TestDataFactory.reload(ids)[0].Review_Reason__c.contains('not linked to an application'),
                'Reason given'
            );
        }
    }

    @IsTest
    static void bulkTwoHundredDocumentsAllocateInOneJob() {
        System.runAs(TestDataFactory.pipelineUser()) {
            TestDataFactory.useSettings(80, 4, 1);
            Set<Id> ids = TestDataFactory.idsOf(
                TestDataFactory.createClassifiedIntakes(application().Id, 200, TestDataFactory.classified('Bank Statement', 95))
            );

            Test.startTest();
            DocumentAllocationService.Summary summary = DocumentAllocationService.allocate(ids);
            Integer queries = Limits.getQueries();
            Integer dmlStatements = Limits.getDmlStatements();
            Test.stopTest();

            Assert.areEqual(200, summary.allocated, 'All 200 allocated');
            Assert.isTrue(summary.saveErrors.isEmpty(), 'No save errors');
            Assert.areEqual(
                200,
                [SELECT COUNT() FROM Document_Intake__c WHERE Status__c = :IntakeStatus.ALLOCATED],
                'All 200 saved'
            );
            // allocate: 2 queries + 1 update. Trigger after update: 1 query + 1 update.
            Assert.areEqual(3, queries, 'Query count does not grow with record count');
            Assert.areEqual(2, dmlStatements, 'DML count does not grow with record count');
        }
    }

    @IsTest
    static void onlyClassifyingRecordsAreTouched() {
        System.runAs(TestDataFactory.pipelineUser()) {
            List<Document_Intake__c> intakes = TestDataFactory.createClassifiedIntakes(application().Id, 1, TestDataFactory.classified('Bank Statement', 99));
            intakes[0].Status__c = IntakeStatus.FAILED;
            update intakes;

            DocumentAllocationService.Summary summary = DocumentAllocationService.allocate(TestDataFactory.idsOf(intakes));

            Assert.areEqual(0, summary.allocated + summary.needsReview, 'Failed records are left alone');
            Assert.areEqual(0, DocumentAllocationService.allocate(new Set<Id>()).allocated, 'Empty input is a no-op');
            Assert.areEqual(0, DocumentAllocationService.allocate(null).allocated, 'Null input is a no-op');
        }
    }

    @IsTest
    static void finalizerMovesStuckDocumentsToReview() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Set<Id> ids = TestDataFactory.idsOf(
                TestDataFactory.createClassifiedIntakes(application().Id, 3, TestDataFactory.classified('Bank Statement', 95))
            );

            Test.startTest();
            Integer moved = DocumentAllocationFinalizer.markStuck(ids, 'System.LimitException: Too many DML rows');
            Test.stopTest();

            Assert.areEqual(3, moved, 'All stuck records moved');
            for (Document_Intake__c intake : TestDataFactory.reload(ids)) {
                Assert.areEqual(IntakeStatus.NEEDS_REVIEW, intake.Status__c, 'A person takes over');
                Assert.isTrue(intake.Last_Error__c.contains('Too many DML rows'), 'Cause recorded');
            }
            Assert.areEqual(0, DocumentAllocationFinalizer.markStuck(null, 'x'), 'Null input is a no-op');
        }
    }
}
