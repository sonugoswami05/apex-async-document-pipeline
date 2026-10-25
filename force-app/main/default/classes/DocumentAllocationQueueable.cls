/**
 * Runs allocation in its own transaction after a batch chunk has saved its classification results.
 * No callouts here, so no Database.AllowsCallouts.
 *
 * A Transaction Finalizer is attached first. If this job dies with an unhandled error (a limit,
 * a lock timeout), the finalizer still runs and moves the documents to Needs_Review with the error,
 * so nothing is left sitting in Classifying.
 */
public with sharing class DocumentAllocationQueueable implements Queueable {
    @TestVisible
    private final Set<Id> intakeIds;

    public DocumentAllocationQueueable(Set<Id> intakeIds) {
        this.intakeIds = intakeIds == null ? new Set<Id>() : new Set<Id>(intakeIds);
    }

    public void execute(QueueableContext context) {
        System.attachFinalizer(new DocumentAllocationFinalizer(intakeIds));
        DocumentAllocationService.Summary summary = DocumentAllocationService.allocate(intakeIds);
        for (String error : summary.saveErrors) {
            System.debug(LoggingLevel.ERROR, 'Allocation save failed: ' + error);
        }
    }
}
