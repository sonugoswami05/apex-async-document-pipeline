/**
 * Logic for DocumentIntakeTrigger. Bulk-safe: one query and one DML at most, whatever the batch size.
 *
 *   before insert   set the starting status (Uploading until the file is attached, then Queued)
 *   before update   promote Uploading to Queued when the file arrives; reset attempts on a manual
 *                   re-queue of a Failed or Needs_Review document
 *   after update    mark the checklist item Received when a document is allocated to it
 */
public with sharing class DocumentIntakeTriggerHandler {
    /**
     * Ids already handled by afterUpdate in this transaction.
     *
     * Why a Set<Id> and not a static Boolean: a large DML (Data Loader, a 1,000-row update) runs
     * the trigger in chunks of 200 inside the same transaction. A Boolean set by the first chunk
     * would skip every later chunk, silently. A Set only skips the exact records already handled,
     * which is the real goal: when a flow or another trigger updates the same record again in this
     * transaction, Trigger.old still holds the pre-transaction values, so the Allocated transition
     * would look new and fire twice.
     */
    @TestVisible
    private static Set<Id> processedAfterUpdate = new Set<Id>();

    private final List<Document_Intake__c> newRecords;
    private final Map<Id, Document_Intake__c> oldRecords;
    private final System.TriggerOperation operation;

    public DocumentIntakeTriggerHandler() {
        this(Trigger.new, (Map<Id, Document_Intake__c>) Trigger.oldMap, Trigger.operationType);
    }

    @TestVisible
    private DocumentIntakeTriggerHandler(
        List<Document_Intake__c> newRecords, Map<Id, Document_Intake__c> oldRecords, System.TriggerOperation operation
    ) {
        this.newRecords = newRecords == null ? new List<Document_Intake__c>() : newRecords;
        this.oldRecords = oldRecords == null ? new Map<Id, Document_Intake__c>() : oldRecords;
        this.operation = operation;
    }

    public void run() {
        switch on operation {
            when BEFORE_INSERT {
                beforeInsert();
            }
            when BEFORE_UPDATE {
                beforeUpdate();
            }
            when AFTER_UPDATE {
                afterUpdate();
            }
        }
    }

    private void beforeInsert() {
        for (Document_Intake__c intake : newRecords) {
            if (intake.Attempt_Count__c == null) {
                intake.Attempt_Count__c = 0;
            }
            if (String.isBlank(intake.Status__c) || intake.Status__c == IntakeStatus.UPLOADING) {
                intake.Status__c = String.isBlank(intake.Content_Document_Id__c) ? IntakeStatus.UPLOADING : IntakeStatus.QUEUED;
            }
        }
    }

    private void beforeUpdate() {
        for (Document_Intake__c intake : newRecords) {
            Document_Intake__c previous = oldRecords.get(intake.Id);
            if (previous == null) {
                continue;
            }
            Boolean fileJustArrived = String.isBlank(previous.Content_Document_Id__c)
                && String.isNotBlank(intake.Content_Document_Id__c);
            if (fileJustArrived && intake.Status__c == IntakeStatus.UPLOADING) {
                intake.Status__c = IntakeStatus.QUEUED;
            }

            Boolean manualRequeue = intake.Status__c == IntakeStatus.QUEUED
                && (previous.Status__c == IntakeStatus.FAILED || previous.Status__c == IntakeStatus.NEEDS_REVIEW);
            if (manualRequeue) {
                // Fresh start: the batch picks up attempt 0. Last_Error__c is kept as history.
                intake.Attempt_Count__c = 0;
                intake.Next_Attempt_At__c = null;
                intake.Review_Reason__c = null;
            }
        }
    }

    private void afterUpdate() {
        Set<Id> itemIds = new Set<Id>();
        for (Document_Intake__c intake : newRecords) {
            if (processedAfterUpdate.contains(intake.Id)) {
                continue;
            }
            Document_Intake__c previous = oldRecords.get(intake.Id);
            Boolean becameAllocated = intake.Status__c == IntakeStatus.ALLOCATED
                && (previous == null || previous.Status__c != IntakeStatus.ALLOCATED);
            if (becameAllocated && intake.Checklist_Item__c != null) {
                itemIds.add(intake.Checklist_Item__c);
                processedAfterUpdate.add(intake.Id);
            }
        }
        if (itemIds.isEmpty()) {
            return;
        }

        List<Checklist_Item__c> items = [
            SELECT Id
            FROM Checklist_Item__c
            WHERE Id IN :itemIds AND Status__c = :IntakeStatus.ITEM_OPEN
            WITH USER_MODE
        ];
        for (Checklist_Item__c item : items) {
            item.Status__c = IntakeStatus.ITEM_RECEIVED;
        }
        if (!items.isEmpty()) {
            Database.update(items, AccessLevel.USER_MODE);
        }
    }
}
