/**
 * First-pass classification for every Queued intake.
 *
 * Why the scope is 5
 * ------------------
 * Each record makes CALLOUTS_PER_RECORD = 1 callout with a 20 s timeout. Each execute() is its
 * own transaction, and the limits that matter there are:
 *
 *   100 callouts per transaction     5 records x 1 callout = 5. Lots of headroom, not the constraint.
 *   120 s total callout time         Worst case 5 x 20 s = 100 s, leaving 20 s spare. At scope 6
 *                                    the worst case is exactly 120 s, so one slow file could fail
 *                                    the whole chunk. This is the limit that binds.
 *   12 MB async heap                 Files are capped at 1 MB. 5 file bodies = 5 MB, plus one
 *                                    base64 copy and one JSON body for the file being sent
 *                                    (about 1.33 MB each), so the peak is about 8 MB.
 *
 * So scope = floor(120 s / (callouts per record x timeout)) - 1 = floor(120 / 20) - 1 = 5.
 * SCOPE_SIZE below is computed from the same inputs, so adding a second callout per record
 * (say, an OCR step) drops it to floor(120 / 40) - 1 = 2 without anyone editing a magic number.
 *
 * Why Database.Stateful
 * ---------------------
 * Without it every execute() starts from a fresh copy of the batch object, so counters would
 * reset each chunk. Stateful carries them across chunks. The cost is that instance state is
 * serialized between chunks, so it holds only integers and Ids, never sObjects or file bodies.
 */
public with sharing class DocumentClassificationBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {
    public static final Integer CALLOUTS_PER_RECORD = 1;
    private static final Integer CALLOUT_TIME_LIMIT_SECONDS = 120;
    public static final Integer SCOPE_SIZE = Math.max(
        1,
        CALLOUT_TIME_LIMIT_SECONDS / (CALLOUTS_PER_RECORD * (DocumentClassifierService.TIMEOUT_MS / 1000)) - 1
    );

    /**
     * A retry chain re-enqueues itself at most 10 minutes ahead. A Queued retry that is 30 minutes
     * overdue means that chain died (for example, an unhandled error), so this batch picks it up.
     */
    @TestVisible
    private static final Integer STALE_RETRY_MINUTES = 30;

    @TestVisible
    private Integer processed = 0;
    @TestVisible
    private Integer classified = 0;
    @TestVisible
    private Integer sentToReview = 0;
    @TestVisible
    private Integer failed = 0;
    @TestVisible
    private Integer saveErrors = 0;
    @TestVisible
    private Set<Id> retryIds = new Set<Id>();

    /** Starts a run unless one is already queued or running. Returns the job Id, or null if skipped. */
    public static Id run() {
        if (isAlreadyRunning()) {
            return null;
        }
        return Database.executeBatch(new DocumentClassificationBatch(), SCOPE_SIZE);
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        Datetime staleCutoff = Datetime.now().addMinutes(-STALE_RETRY_MINUTES);
        return Database.getQueryLocator([
            SELECT Id, Name, Application__c, Attempt_Count__c, Content_Document_Id__c, File_Name__c
            FROM Document_Intake__c
            WHERE Status__c = :IntakeStatus.QUEUED
                AND Content_Document_Id__c != NULL
                AND (Attempt_Count__c = 0 OR Attempt_Count__c = NULL OR Next_Attempt_At__c < :staleCutoff)
            WITH USER_MODE
            ORDER BY CreatedDate
        ]);
    }

    public void execute(Database.BatchableContext context, List<Document_Intake__c> scope) {
        DocumentClassificationProcessor.Outcome outcome = new DocumentClassificationProcessor().process(scope);

        processed += outcome.processed;
        classified += outcome.classifiedIds.size();
        sentToReview += outcome.reviewIds.size();
        failed += outcome.failedIds.size();
        saveErrors += outcome.saveErrors.size();
        retryIds.addAll(outcome.retryIds);

        for (String error : outcome.saveErrors) {
            System.debug(LoggingLevel.ERROR, 'Document intake save failed: ' + error);
        }

        if (!outcome.classifiedIds.isEmpty()) {
            // Allocation runs in its own transaction, so a problem there (a validation rule, a row
            // lock on a checklist item) cannot roll back classification results we already paid a
            // callout for. Batch execute() may enqueue one job, and this is it.
            AsyncJobs.enqueue(new DocumentAllocationQueueable(outcome.classifiedIds), 0);
        }
    }

    public void finish(Database.BatchableContext context) {
        // One retry job for the whole run instead of one per chunk. It wakes up at the earliest
        // Next_Attempt_At__c and reschedules itself until every document has settled.
        DocumentRetryQueueable.enqueueFor(retryIds);
        System.debug(LoggingLevel.INFO, summary());
    }

    public String summary() {
        return String.format(
            'Document classification run: {0} processed, {1} classified, {2} sent to review, {3} retry scheduled, {4} failed, {5} save errors.',
            new List<Object>{ processed, classified, sentToReview, retryIds.size(), failed, saveErrors }
        );
    }

    /**
     * System mode on purpose: the scheduling user may not be able to see jobs another user
     * started, and this read exposes job status only, no business data.
     */
    private static Boolean isAlreadyRunning() {
        return ![
            SELECT Id
            FROM AsyncApexJob
            WHERE JobType = 'BatchApex'
                AND ApexClass.Name = 'DocumentClassificationBatch'
                AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
            WITH SYSTEM_MODE
            LIMIT 1
        ].isEmpty();
    }
}
