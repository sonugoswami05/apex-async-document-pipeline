/**
 * Retries documents whose last attempt failed with a retryable error.
 *
 * The schedule lives on the records: each failed attempt sets Next_Attempt_At__c using
 * RetryPolicy (capped exponential backoff). This job wakes up at the earliest of those times,
 * processes up to one batch scope of due records, then re-enqueues itself for whatever is still
 * waiting. The chain ends when every document is Classifying, Allocated, Needs_Review or Failed.
 *
 * A Queueable can enqueue only one job from inside another async job, and this one needs that slot
 * for its own follow-up. So allocation runs inline here, unlike the batch, which hands it to
 * DocumentAllocationQueueable.
 */
public with sharing class DocumentRetryQueueable implements Queueable, Database.AllowsCallouts {
    /** The enqueue delay is whole minutes, so treat anything due within the next minute as due now. */
    private static final Integer DUE_GRACE_SECONDS = 60;

    @TestVisible
    private final Set<Id> intakeIds;

    public DocumentRetryQueueable(Set<Id> intakeIds) {
        this.intakeIds = intakeIds == null ? new Set<Id>() : new Set<Id>(intakeIds);
    }

    /** Enqueues a retry job for these ids if any of them are still waiting. Returns the job Id or null. */
    public static Id enqueueFor(Set<Id> intakeIds) {
        if (intakeIds == null || intakeIds.isEmpty()) {
            return null;
        }
        List<Document_Intake__c> waiting = [
            SELECT Id, Next_Attempt_At__c
            FROM Document_Intake__c
            WHERE Id IN :intakeIds AND Status__c = :IntakeStatus.QUEUED AND Attempt_Count__c > 0
            WITH USER_MODE
            ORDER BY Next_Attempt_At__c ASC NULLS FIRST
        ];
        if (waiting.isEmpty()) {
            return null;
        }
        Set<Id> remaining = new Map<Id, Document_Intake__c>(waiting).keySet();
        return AsyncJobs.enqueue(new DocumentRetryQueueable(remaining), minutesUntil(waiting[0].Next_Attempt_At__c));
    }

    public void execute(QueueableContext context) {
        Datetime dueBy = Datetime.now().addSeconds(DUE_GRACE_SECONDS);
        Integer maxRecords = DocumentClassificationBatch.SCOPE_SIZE;
        // Records a user re-queued by hand (attempts reset to 0) or moved on are left alone.
        List<Document_Intake__c> due = [
            SELECT Id, Name, Application__c, Attempt_Count__c, Content_Document_Id__c, File_Name__c
            FROM Document_Intake__c
            WHERE Id IN :intakeIds
                AND Status__c = :IntakeStatus.QUEUED
                AND Attempt_Count__c > 0
                AND (Next_Attempt_At__c = NULL OR Next_Attempt_At__c <= :dueBy)
            WITH USER_MODE
            ORDER BY Next_Attempt_At__c ASC NULLS FIRST
            LIMIT :maxRecords
        ];

        DocumentClassificationProcessor.Outcome outcome = new DocumentClassificationProcessor().process(due);
        if (!outcome.classifiedIds.isEmpty()) {
            DocumentAllocationService.allocate(outcome.classifiedIds);
        }
        // A record we could not write to at all would otherwise stay due forever and spin the chain.
        Set<Id> stillTracked = new Set<Id>(intakeIds);
        stillTracked.removeAll(outcome.unsavedIds);
        enqueueFor(stillTracked);
    }

    /** Whole minutes from now until target, rounded up, between 0 and the platform maximum. */
    @TestVisible
    private static Integer minutesUntil(Datetime target) {
        if (target == null) {
            return 0;
        }
        Long millis = target.getTime() - Datetime.now().getTime();
        if (millis <= 0) {
            return 0;
        }
        Integer minutes = (millis / 60000.0).round(System.RoundingMode.CEILING).intValue();
        return Math.min(minutes, RetryPolicy.MAX_DELAY_MINUTES);
    }
}
