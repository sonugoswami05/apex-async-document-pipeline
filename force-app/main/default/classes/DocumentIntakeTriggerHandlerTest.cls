@IsTest
private class DocumentIntakeTriggerHandlerTest {
    @TestSetup
    static void setup() {
        User pipelineUser = TestDataFactory.createPipelineUser();
        System.runAs(pipelineUser) {
            Application__c application = TestDataFactory.createApplication('Trigger test application');
            TestDataFactory.createChecklist(application.Id, new List<String>{ 'Bank Statement' });
        }
    }

    private static Application__c application() {
        return [SELECT Id FROM Application__c LIMIT 1];
    }

    @IsTest
    static void insertSetsStartingStatus() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Id fileId = TestDataFactory.createFile('statement', 64);
            Document_Intake__c waitingForFile = new Document_Intake__c(Application__c = application().Id);
            Document_Intake__c withFile = new Document_Intake__c(Application__c = application().Id, Content_Document_Id__c = fileId);

            Test.startTest();
            insert new List<Document_Intake__c>{ waitingForFile, withFile };
            Test.stopTest();

            List<Document_Intake__c> saved = TestDataFactory.reload(new Set<Id>{ waitingForFile.Id, withFile.Id });
            Map<Id, Document_Intake__c> byId = new Map<Id, Document_Intake__c>(saved);
            Assert.areEqual(IntakeStatus.UPLOADING, byId.get(waitingForFile.Id).Status__c, 'No file yet');
            Assert.areEqual(IntakeStatus.QUEUED, byId.get(withFile.Id).Status__c, 'Ready for the batch');
            Assert.areEqual(0, byId.get(withFile.Id).Attempt_Count__c.intValue(), 'Starts at zero attempts');
        }
    }

    @IsTest
    static void fileArrivalPromotesToQueued() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Document_Intake__c intake = new Document_Intake__c(Application__c = application().Id);
            insert intake;
            Id fileId = TestDataFactory.createFile('statement', 64);

            Test.startTest();
            intake.Content_Document_Id__c = fileId;
            update intake;
            Test.stopTest();

            Assert.areEqual(IntakeStatus.QUEUED, TestDataFactory.reload(new Set<Id>{ intake.Id })[0].Status__c, 'Queued once the file is there');
        }
    }

    @IsTest
    static void manualRequeueResetsAttempts() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Document_Intake__c intake = new Document_Intake__c(
                Application__c = application().Id,
                Content_Document_Id__c = TestDataFactory.createFile('statement', 64),
                Status__c = IntakeStatus.FAILED,
                Attempt_Count__c = 4,
                Last_Error__c = 'HTTP 503',
                Next_Attempt_At__c = Datetime.now()
            );
            insert intake;

            Test.startTest();
            intake.Status__c = IntakeStatus.QUEUED;
            update intake;
            Test.stopTest();

            Document_Intake__c saved = TestDataFactory.reload(new Set<Id>{ intake.Id })[0];
            Assert.areEqual(0, saved.Attempt_Count__c.intValue(), 'Attempts reset so the batch picks it up');
            Assert.isNull(saved.Next_Attempt_At__c, 'Old retry time cleared');
            Assert.areEqual('HTTP 503', saved.Last_Error__c, 'Error history kept');
        }
    }

    @IsTest
    static void allocationMarksChecklistItemReceived() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Checklist_Item__c item = [SELECT Id FROM Checklist_Item__c LIMIT 1];
            List<Document_Intake__c> intakes = TestDataFactory.createClassifiedIntakes(application().Id, 1, TestDataFactory.classified('Bank Statement', 95));

            Test.startTest();
            intakes[0].Status__c = IntakeStatus.ALLOCATED;
            intakes[0].Checklist_Item__c = item.Id;
            update intakes;
            Test.stopTest();

            Assert.areEqual(
                IntakeStatus.ITEM_RECEIVED,
                [SELECT Status__c FROM Checklist_Item__c WHERE Id = :item.Id].Status__c,
                'Item received'
            );
        }
    }

    @IsTest
    static void recursionGuardSkipsRecordsAlreadyHandled() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Checklist_Item__c item = [SELECT Id FROM Checklist_Item__c LIMIT 1];
            Document_Intake__c before = TestDataFactory.createClassifiedIntakes(application().Id, 1, TestDataFactory.classified('Bank Statement', 95))[0];
            Document_Intake__c after = before.clone(true, true, false, false);
            after.Status__c = IntakeStatus.ALLOCATED;
            after.Checklist_Item__c = item.Id;
            List<Document_Intake__c> newRecords = new List<Document_Intake__c>{ after };
            Map<Id, Document_Intake__c> oldRecords = new Map<Id, Document_Intake__c>{ before.Id => before };

            Test.startTest();
            new DocumentIntakeTriggerHandler(newRecords, oldRecords, System.TriggerOperation.AFTER_UPDATE).run();
            Integer dmlAfterFirstRun = Limits.getDmlStatements();
            // Same transaction, same records, Trigger.old unchanged: what a flow re-firing the trigger looks like.
            new DocumentIntakeTriggerHandler(newRecords, oldRecords, System.TriggerOperation.AFTER_UPDATE).run();
            Integer dmlAfterSecondRun = Limits.getDmlStatements();
            Test.stopTest();

            Assert.areEqual(1, dmlAfterFirstRun, 'First pass updates the checklist item');
            Assert.areEqual(dmlAfterFirstRun, dmlAfterSecondRun, 'Second pass is skipped by the guard');
            Assert.isTrue(DocumentIntakeTriggerHandler.processedAfterUpdate.contains(before.Id), 'Id remembered');
        }
    }

    @IsTest
    static void guardDoesNotBlockOtherRecordsInTheSameTransaction() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Application__c application = application();
            List<Checklist_Item__c> items = TestDataFactory.createChecklist(
                application.Id, new List<String>{ 'Photo ID', 'Pay Stub' }
            );
            List<Document_Intake__c> first = TestDataFactory.createClassifiedIntakes(application.Id, 1, TestDataFactory.classified('Photo ID', 95));
            List<Document_Intake__c> second = TestDataFactory.createClassifiedIntakes(application.Id, 1, TestDataFactory.classified('Pay Stub', 95));

            Test.startTest();
            first[0].Status__c = IntakeStatus.ALLOCATED;
            first[0].Checklist_Item__c = items[0].Id;
            update first;
            // A Boolean guard would stop here. The Set guard only skips Ids it has seen.
            second[0].Status__c = IntakeStatus.ALLOCATED;
            second[0].Checklist_Item__c = items[1].Id;
            update second;
            Test.stopTest();

            Assert.areEqual(
                2,
                [SELECT COUNT() FROM Checklist_Item__c WHERE Id IN :items AND Status__c = :IntakeStatus.ITEM_RECEIVED],
                'Both items received'
            );
        }
    }

    @IsTest
    static void bulkInsertAndUpdateTwoHundredRecords() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Id fileId = TestDataFactory.createFile('statement', 64);
            Checklist_Item__c item = [SELECT Id FROM Checklist_Item__c LIMIT 1];
            List<Document_Intake__c> intakes = TestDataFactory.buildIntakes(application().Id, null, 200);
            for (Integer i = 0; i < intakes.size(); i++) {
                if (Math.mod(i, 2) == 0) {
                    intakes[i].Content_Document_Id__c = fileId;
                }
            }

            Test.startTest();
            insert intakes;
            for (Document_Intake__c intake : intakes) {
                intake.Status__c = IntakeStatus.ALLOCATED;
                intake.Checklist_Item__c = item.Id;
            }
            update intakes;
            Integer queries = Limits.getQueries();
            Test.stopTest();

            Assert.areEqual(200, [SELECT COUNT() FROM Document_Intake__c WHERE Status__c = :IntakeStatus.ALLOCATED], 'All saved');
            Assert.areEqual(1, queries, 'One query for 200 records');
            Assert.areEqual(
                IntakeStatus.ITEM_RECEIVED,
                [SELECT Status__c FROM Checklist_Item__c WHERE Id = :item.Id].Status__c,
                'Item received once'
            );
        }
    }

    @IsTest
    static void bulkInsertSetsStatusPerRecord() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Id fileId = TestDataFactory.createFile('statement', 64);
            List<Document_Intake__c> intakes = TestDataFactory.buildIntakes(application().Id, null, 200);
            for (Integer i = 0; i < 100; i++) {
                intakes[i].Content_Document_Id__c = fileId;
            }

            Test.startTest();
            insert intakes;
            Test.stopTest();

            Assert.areEqual(100, [SELECT COUNT() FROM Document_Intake__c WHERE Status__c = :IntakeStatus.QUEUED], 'Half queued');
            Assert.areEqual(100, [SELECT COUNT() FROM Document_Intake__c WHERE Status__c = :IntakeStatus.UPLOADING], 'Half uploading');
        }
    }
}
