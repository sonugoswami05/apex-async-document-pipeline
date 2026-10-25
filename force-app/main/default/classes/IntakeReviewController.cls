/**
 * Backs the intakeReview LWC: lists Needs_Review documents and saves reviewer decisions.
 * Reads are cacheable; the component calls refreshApex after a save. Everything runs in user mode,
 * so a reviewer only sees and changes what their sharing and field access allow.
 */
public with sharing class IntakeReviewController {
    @TestVisible
    private static final Integer MAX_ROWS = 200;

    /** Documents waiting for review, oldest first. Pass an application Id to filter, or null for all. */
    @AuraEnabled(cacheable=true)
    public static List<ReviewRow> getDocumentsForReview(Id applicationId) {
        List<Document_Intake__c> intakes;
        if (applicationId == null) {
            intakes = [
                SELECT Id, Name, File_Name__c, Application__c, Application__r.Name, Suggested_Type__c,
                    Confidence__c, Review_Reason__c, Attempt_Count__c
                FROM Document_Intake__c
                WHERE Status__c = :IntakeStatus.NEEDS_REVIEW
                WITH USER_MODE
                ORDER BY CreatedDate ASC
                LIMIT :MAX_ROWS
            ];
        } else {
            intakes = [
                SELECT Id, Name, File_Name__c, Application__c, Application__r.Name, Suggested_Type__c,
                    Confidence__c, Review_Reason__c, Attempt_Count__c
                FROM Document_Intake__c
                WHERE Status__c = :IntakeStatus.NEEDS_REVIEW AND Application__c = :applicationId
                WITH USER_MODE
                ORDER BY CreatedDate ASC
                LIMIT :MAX_ROWS
            ];
        }

        List<ReviewRow> rows = new List<ReviewRow>();
        for (Document_Intake__c intake : intakes) {
            rows.add(new ReviewRow(intake));
        }
        return rows;
    }

    /** Combobox options, taken from the checklist document type picklist. */
    @AuraEnabled(cacheable=true)
    public static List<TypeOption> getDocumentTypeOptions() {
        List<TypeOption> options = new List<TypeOption>();
        for (String value : DocumentTypes.values()) {
            options.add(new TypeOption(value));
        }
        return options;
    }

    /**
     * Applies reviewer decisions. Each decision either allocates the document to the open checklist
     * item of the chosen type or comes back with a reason it could not. One bad row never blocks
     * the others.
     */
    @AuraEnabled
    public static List<DecisionResult> saveDecisions(List<Decision> decisions) {
        if (decisions == null || decisions.isEmpty()) {
            throw auraError('Select at least one document.');
        }
        if (decisions.size() > MAX_ROWS) {
            throw auraError('Save at most ' + MAX_ROWS + ' documents at a time.');
        }

        Map<Id, String> typeByIntake = typesByIntake(decisions);
        Map<Id, Document_Intake__c> intakes = new Map<Id, Document_Intake__c>([
            SELECT Id, Application__c
            FROM Document_Intake__c
            WHERE Id IN :typeByIntake.keySet() AND Status__c = :IntakeStatus.NEEDS_REVIEW
            WITH USER_MODE
        ]);
        Map<String, Checklist_Item__c> openItems = DocumentAllocationService.openItemsByKey(applicationIdsOf(intakes.values()));

        List<DecisionResult> results = new List<DecisionResult>();
        List<Document_Intake__c> changes = new List<Document_Intake__c>();
        List<DecisionResult> pending = new List<DecisionResult>();

        for (Id intakeId : typeByIntake.keySet()) {
            String documentType = typeByIntake.get(intakeId);
            Document_Intake__c intake = intakes.get(intakeId);
            Checklist_Item__c item = intake == null
                ? null
                : openItems.get(DocumentAllocationService.itemKey(intake.Application__c, documentType));
            String problem = rejectionReason(intake, documentType, item);
            if (problem != null) {
                results.add(rejected(intakeId, problem));
                continue;
            }
            // Suggested_Type__c is left as the classifier said it, so overrides stay auditable.
            changes.add(new Document_Intake__c(
                Id = intakeId,
                Status__c = IntakeStatus.ALLOCATED,
                Checklist_Item__c = item.Id,
                Confirmed_Type__c = documentType,
                Review_Reason__c = null
            ));
            pending.add(accepted(intakeId, 'Allocated to ' + item.Name + '.'));
        }

        results.addAll(applySaves(changes, pending));
        return results;
    }

    /** Latest decision per intake, with the type normalized onto the picklist. */
    private static Map<Id, String> typesByIntake(List<Decision> decisions) {
        Map<Id, String> typeByIntake = new Map<Id, String>();
        for (Decision decision : decisions) {
            if (decision != null && decision.intakeId != null) {
                typeByIntake.put(decision.intakeId, DocumentTypes.normalize(decision.documentType));
            }
        }
        return typeByIntake;
    }

    private static Set<Id> applicationIdsOf(List<Document_Intake__c> intakes) {
        Set<Id> applicationIds = new Set<Id>();
        for (Document_Intake__c intake : intakes) {
            if (intake.Application__c != null) {
                applicationIds.add(intake.Application__c);
            }
        }
        return applicationIds;
    }

    /** Null when the decision can be applied, otherwise a message for the reviewer. */
    private static String rejectionReason(Document_Intake__c intake, String documentType, Checklist_Item__c item) {
        if (intake == null) {
            return 'This document is no longer waiting for review.';
        }
        if (String.isBlank(documentType)) {
            return 'Choose a document type.';
        }
        if (item == null) {
            return 'No open checklist item for type "' + documentType + '" on this application.';
        }
        return null;
    }

    /** Partial-success save; a row the database rejects comes back with the database's reason. */
    private static List<DecisionResult> applySaves(List<Document_Intake__c> changes, List<DecisionResult> pending) {
        if (changes.isEmpty()) {
            return pending;
        }
        List<Database.SaveResult> saves = Database.update(changes, false, AccessLevel.USER_MODE);
        for (Integer i = 0; i < saves.size(); i++) {
            if (!saves[i].isSuccess()) {
                pending[i] = rejected(pending[i].intakeId, saves[i].getErrors()[0].getMessage());
            }
        }
        return pending;
    }

    // Static factories live here because Apex allows static methods only on outer classes.
    private static DecisionResult accepted(Id intakeId, String message) {
        DecisionResult result = new DecisionResult(intakeId, message);
        result.success = true;
        return result;
    }

    private static DecisionResult rejected(Id intakeId, String message) {
        DecisionResult result = new DecisionResult(intakeId, message);
        result.success = false;
        return result;
    }

    private static AuraHandledException auraError(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }

    // ---------------------------------------------------------------------------------------
    // DTOs exchanged with the component
    // ---------------------------------------------------------------------------------------

    public class ReviewRow {
        @AuraEnabled
        public Id intakeId;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String fileName;
        @AuraEnabled
        public Id applicationId;
        @AuraEnabled
        public String applicationName;
        @AuraEnabled
        public String suggestedType;
        /** Fraction from 0 to 1, which is what lightning-datatable's percent type expects. */
        @AuraEnabled
        public Decimal confidence;
        @AuraEnabled
        public String reviewReason;
        @AuraEnabled
        public Integer attemptCount;

        public ReviewRow(Document_Intake__c intake) {
            intakeId = intake.Id;
            name = intake.Name;
            fileName = intake.File_Name__c;
            applicationId = intake.Application__c;
            applicationName = intake.Application__r?.Name;
            suggestedType = intake.Suggested_Type__c;
            confidence = intake.Confidence__c == null ? null : (intake.Confidence__c / 100).setScale(4);
            reviewReason = intake.Review_Reason__c;
            attemptCount = intake.Attempt_Count__c == null ? 0 : intake.Attempt_Count__c.intValue();
        }
    }

    public class TypeOption {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String value;

        public TypeOption(String value) {
            this.label = value;
            this.value = value;
        }
    }

    /** One reviewer decision sent from the component. */
    public class Decision {
        @AuraEnabled
        public Id intakeId { get; set; }
        @AuraEnabled
        public String documentType { get; set; }
    }

    public class DecisionResult {
        @AuraEnabled
        public Id intakeId;
        @AuraEnabled
        public Boolean success;
        @AuraEnabled
        public String message;

        public DecisionResult(Id intakeId, String message) {
            this.intakeId = intakeId;
            this.message = message;
        }
    }
}
