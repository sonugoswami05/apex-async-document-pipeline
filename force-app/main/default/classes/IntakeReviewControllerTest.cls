@IsTest
private class IntakeReviewControllerTest {
    @TestSetup
    static void setup() {
        User pipelineUser = TestDataFactory.createPipelineUser();
        System.runAs(pipelineUser) {
            Application__c first = TestDataFactory.createApplication('First application');
            Application__c second = TestDataFactory.createApplication('Second application');
            TestDataFactory.createChecklist(first.Id, new List<String>{ 'Bank Statement', 'Photo ID' });
            TestDataFactory.createChecklist(second.Id, new List<String>{ 'Bank Statement' });

            List<Document_Intake__c> intakes = new List<Document_Intake__c>();
            intakes.addAll(TestDataFactory.createClassifiedIntakes(first.Id, 3, TestDataFactory.classified('Bank Statement', 62)));
            intakes.addAll(TestDataFactory.createClassifiedIntakes(second.Id, 1, TestDataFactory.classified('Pay Stub', 55)));
            for (Document_Intake__c intake : intakes) {
                intake.Status__c = IntakeStatus.NEEDS_REVIEW;
                intake.Review_Reason__c = 'Low confidence';
            }
            update intakes;
            // One document that does not need review.
            TestDataFactory.createClassifiedIntakes(first.Id, 1, TestDataFactory.classified('Bank Statement', 99));
        }
    }

    private static Id applicationId(String name) {
        return [SELECT Id FROM Application__c WHERE Name = :name LIMIT 1].Id;
    }

    private static IntakeReviewController.Decision decision(Id intakeId, String documentType) {
        IntakeReviewController.Decision decision = new IntakeReviewController.Decision();
        decision.intakeId = intakeId;
        decision.documentType = documentType;
        return decision;
    }

    private static List<Document_Intake__c> inReview(Id applicationId) {
        return [
            SELECT Id FROM Document_Intake__c
            WHERE Application__c = :applicationId AND Status__c = :IntakeStatus.NEEDS_REVIEW
            ORDER BY CreatedDate, Id
        ];
    }

    @IsTest
    static void listsDocumentsNeedingReview() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Test.startTest();
            List<IntakeReviewController.ReviewRow> all = IntakeReviewController.getDocumentsForReview(null);
            List<IntakeReviewController.ReviewRow> first = IntakeReviewController.getDocumentsForReview(applicationId('First application'));
            Test.stopTest();

            Assert.areEqual(4, all.size(), 'All review rows, nothing else');
            Assert.areEqual(3, first.size(), 'Filtered by application');
            IntakeReviewController.ReviewRow row = first[0];
            Assert.isTrue(row.confidence == 0.62, 'Percent becomes a fraction for the datatable, got ' + row.confidence);
            Assert.areEqual('First application', row.applicationName, 'Parent name included');
            Assert.areEqual('Bank Statement', row.suggestedType, 'Suggestion included');
            Assert.areEqual('Low confidence', row.reviewReason, 'Reason included');
            Assert.areEqual(1, row.attemptCount, 'Attempts included');
            Assert.isNotNull(row.intakeId, 'Key field set');
        }
    }

    @IsTest
    static void typeOptionsComeFromThePicklist() {
        List<IntakeReviewController.TypeOption> options = IntakeReviewController.getDocumentTypeOptions();
        Set<String> values = new Set<String>();
        for (IntakeReviewController.TypeOption option : options) {
            values.add(option.value);
            Assert.areEqual(option.value, option.label, 'Label mirrors value');
        }
        Assert.isTrue(values.contains('Bank Statement'), 'Known type offered');
        Assert.isTrue(values.contains('Photo ID'), 'Known type offered');
    }

    @IsTest
    static void acceptingTheSuggestionAllocates() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Id firstApplicationId = applicationId('First application');
            Id intakeId = inReview(firstApplicationId)[0].Id;

            Test.startTest();
            List<IntakeReviewController.DecisionResult> results = IntakeReviewController.saveDecisions(
                new List<IntakeReviewController.Decision>{ decision(intakeId, 'Bank Statement') }
            );
            Test.stopTest();

            Assert.isTrue(results[0].success, results[0].message);
            Document_Intake__c saved = TestDataFactory.reload(new Set<Id>{ intakeId })[0];
            Assert.areEqual(IntakeStatus.ALLOCATED, saved.Status__c, 'Allocated');
            Assert.areEqual('Bank Statement', saved.Confirmed_Type__c, 'Confirmed type recorded');
            Assert.isNull(saved.Review_Reason__c, 'Review reason cleared');
            Assert.areEqual(
                IntakeStatus.ITEM_RECEIVED,
                [SELECT Status__c FROM Checklist_Item__c WHERE Id = :saved.Checklist_Item__c].Status__c,
                'Checklist item received'
            );
        }
    }

    @IsTest
    static void overrideKeepsTheOriginalSuggestion() {
        System.runAs(TestDataFactory.pipelineUser()) {
            Id intakeId = inReview(applicationId('First application'))[0].Id;

            Test.startTest();
            List<IntakeReviewController.DecisionResult> results = IntakeReviewController.saveDecisions(
                new List<IntakeReviewController.Decision>{ decision(intakeId, 'photo id') }
            );
            Test.stopTest();

            Assert.isTrue(results[0].success, results[0].message);
            Document_Intake__c saved = TestDataFactory.reload(new Set<Id>{ intakeId })[0];
            Assert.areEqual('Photo ID', saved.Confirmed_Type__c, 'Override normalized and applied');
            Assert.areEqual('Bank Statement', saved.Suggested_Type__c, 'Classifier suggestion kept for audit');
        }
    }

    @IsTest
    static void badRowsFailWithoutBlockingGoodOnes() {
        System.runAs(TestDataFactory.pipelineUser()) {
            List<Document_Intake__c> firstReview = inReview(applicationId('First application'));
            Id notInReview = [
                SELECT Id FROM Document_Intake__c WHERE Status__c = :IntakeStatus.CLASSIFYING LIMIT 1
            ].Id;

            Test.startTest();
            List<IntakeReviewController.DecisionResult> results = IntakeReviewController.saveDecisions(
                new List<IntakeReviewController.Decision>{
                    decision(firstReview[0].Id, 'Tax Return'),
                    decision(firstReview[1].Id, ''),
                    decision(notInReview, 'Bank Statement'),
                    decision(firstReview[2].Id, 'Bank Statement')
                }
            );
            Test.stopTest();

            Map<Id, IntakeReviewController.DecisionResult> byId = new Map<Id, IntakeReviewController.DecisionResult>();
            for (IntakeReviewController.DecisionResult result : results) {
                byId.put(result.intakeId, result);
            }
            Assert.areEqual(4, results.size(), 'One result per decision');
            Assert.isFalse(byId.get(firstReview[0].Id).success, 'No Tax Return item');
            Assert.isTrue(byId.get(firstReview[0].Id).message.contains('No open checklist item'), 'Reason given');
            Assert.areEqual('Choose a document type.', byId.get(firstReview[1].Id).message, 'Blank type rejected');
            Assert.isTrue(byId.get(notInReview).message.contains('no longer waiting'), 'Stale row rejected');
            Assert.isTrue(byId.get(firstReview[2].Id).success, 'Good row still saved');
        }
    }

    @IsTest
    static void emptyOrOversizedRequestsAreRejected() {
        System.runAs(TestDataFactory.pipelineUser()) {
            try {
                IntakeReviewController.saveDecisions(new List<IntakeReviewController.Decision>());
                Assert.fail('Empty list should throw');
            } catch (AuraHandledException e) {
                Assert.areEqual('Select at least one document.', e.getMessage(), 'Readable message');
            }

            List<IntakeReviewController.Decision> tooMany = new List<IntakeReviewController.Decision>();
            for (Integer i = 0; i <= IntakeReviewController.MAX_ROWS; i++) {
                tooMany.add(decision(null, 'Bank Statement'));
            }
            try {
                IntakeReviewController.saveDecisions(tooMany);
                Assert.fail('Oversized list should throw');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('at most'), 'Readable message');
            }
        }
    }
}
