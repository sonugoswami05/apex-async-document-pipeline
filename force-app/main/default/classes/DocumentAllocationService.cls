/**
 * Maps classified documents to checklist items.
 *
 * A Classifying intake is Allocated when all of these hold:
 *   - its confidence is at or above Pipeline_Setting__mdt.Default.Confidence_Threshold__c
 *   - it is linked to an application
 *   - that application has an Open checklist item for the suggested type
 * Otherwise it goes to Needs_Review with a plain-language Review_Reason__c.
 */
public with sharing class DocumentAllocationService {
    /** Per-call counts, mostly for logging and tests. */
    public class Summary {
        public Integer allocated = 0;
        public Integer needsReview = 0;
        public List<String> saveErrors = new List<String>();
    }

    public static Summary allocate(Set<Id> intakeIds) {
        Summary summary = new Summary();
        if (intakeIds == null || intakeIds.isEmpty()) {
            return summary;
        }

        List<Document_Intake__c> intakes = [
            SELECT Id, Application__c, Suggested_Type__c, Confidence__c
            FROM Document_Intake__c
            WHERE Id IN :intakeIds AND Status__c = :IntakeStatus.CLASSIFYING
            WITH USER_MODE
        ];
        if (intakes.isEmpty()) {
            return summary;
        }

        Set<Id> applicationIds = new Set<Id>();
        for (Document_Intake__c intake : intakes) {
            if (intake.Application__c != null) {
                applicationIds.add(intake.Application__c);
            }
        }
        Map<String, Checklist_Item__c> openItems = openItemsByKey(applicationIds);
        Decimal threshold = PipelineSettings.confidenceThreshold();

        List<Document_Intake__c> changes = new List<Document_Intake__c>();
        for (Document_Intake__c intake : intakes) {
            changes.add(decide(intake, openItems, threshold));
        }

        saveWithFallback(changes, summary);
        return summary;
    }

    /**
     * Partial-success save. Anything that cannot be saved is handed to a person (Needs_Review with
     * the error) rather than left sitting in Classifying.
     */
    private static void saveWithFallback(List<Document_Intake__c> changes, Summary summary) {
        List<Database.SaveResult> results = Database.update(changes, false, AccessLevel.USER_MODE);
        List<Document_Intake__c> fallbacks = new List<Document_Intake__c>();
        for (Integer i = 0; i < results.size(); i++) {
            Document_Intake__c change = changes[i];
            if (!results[i].isSuccess()) {
                String message = results[i].getErrors()[0].getMessage();
                summary.saveErrors.add(change.Id + ': ' + message);
                fallbacks.add(new Document_Intake__c(
                    Id = change.Id,
                    Status__c = IntakeStatus.NEEDS_REVIEW,
                    Review_Reason__c = 'Automatic allocation could not be saved. See Last Error.',
                    Last_Error__c = ('Allocation save failed: ' + message).left(32768)
                ));
            } else if (change.Status__c == IntakeStatus.ALLOCATED) {
                summary.allocated++;
            } else {
                summary.needsReview++;
            }
        }
        if (!fallbacks.isEmpty()) {
            Database.update(fallbacks, false, AccessLevel.USER_MODE);
        }
    }

    /** Pure decision for one intake. No queries or DML, so it is cheap to test directly. */
    @TestVisible
    private static Document_Intake__c decide(
        Document_Intake__c intake, Map<String, Checklist_Item__c> openItems, Decimal threshold
    ) {
        Document_Intake__c change = new Document_Intake__c(Id = intake.Id);
        Checklist_Item__c item = openItems.get(itemKey(intake.Application__c, intake.Suggested_Type__c));

        String reason;
        if (intake.Confidence__c == null || intake.Confidence__c < threshold) {
            reason = 'Confidence ' + formatPercent(intake.Confidence__c) + ' is below the '
                + formatPercent(threshold) + ' threshold.';
        } else if (intake.Application__c == null) {
            reason = 'Document is not linked to an application.';
        } else if (item == null) {
            reason = 'No open checklist item for type "' + intake.Suggested_Type__c + '".';
        }

        if (reason != null) {
            change.Status__c = IntakeStatus.NEEDS_REVIEW;
            change.Review_Reason__c = reason.left(255);
            return change;
        }

        change.Status__c = IntakeStatus.ALLOCATED;
        change.Checklist_Item__c = item.Id;
        change.Confirmed_Type__c = intake.Suggested_Type__c;
        change.Review_Reason__c = null;
        return change;
    }

    /**
     * Open checklist items keyed by itemKey(). When an application has two open items of the same
     * type, the oldest one is filled first.
     */
    public static Map<String, Checklist_Item__c> openItemsByKey(Set<Id> applicationIds) {
        Map<String, Checklist_Item__c> byKey = new Map<String, Checklist_Item__c>();
        if (applicationIds == null || applicationIds.isEmpty()) {
            return byKey;
        }
        for (Checklist_Item__c item : [
            SELECT Id, Name, Application__c, Required_Document_Type__c
            FROM Checklist_Item__c
            WHERE Application__c IN :applicationIds AND Status__c = :IntakeStatus.ITEM_OPEN
            WITH USER_MODE
            ORDER BY CreatedDate ASC
        ]) {
            String key = itemKey(item.Application__c, item.Required_Document_Type__c);
            if (!byKey.containsKey(key)) {
                byKey.put(key, item);
            }
        }
        return byKey;
    }

    /** Case-insensitive application + type key. */
    public static String itemKey(Id applicationId, String documentType) {
        return applicationId + '|' + (documentType == null ? '' : documentType.trim().toLowerCase());
    }

    private static String formatPercent(Decimal value) {
        return value == null ? 'unknown' : value.setScale(1) + '%';
    }
}
