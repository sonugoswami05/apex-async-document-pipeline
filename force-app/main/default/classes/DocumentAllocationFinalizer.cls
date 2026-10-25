/**
 * Safety net for DocumentAllocationQueueable. Runs in a fresh transaction after the job ends,
 * even when the job threw an exception the platform could not hand back to us.
 */
public with sharing class DocumentAllocationFinalizer implements Finalizer {
    private final Set<Id> intakeIds;

    public DocumentAllocationFinalizer(Set<Id> intakeIds) {
        this.intakeIds = intakeIds == null ? new Set<Id>() : new Set<Id>(intakeIds);
    }

    public void execute(FinalizerContext context) {
        if (context.getResult() == ParentJobResult.UNHANDLED_EXCEPTION) {
            Exception error = context.getException();
            markStuck(intakeIds, error == null ? 'Unknown error' : error.getTypeName() + ': ' + error.getMessage());
        }
    }

    /** Moves any intake still in Classifying to Needs_Review and records why. Returns how many moved. */
    @TestVisible
    private static Integer markStuck(Set<Id> intakeIds, String message) {
        if (intakeIds == null || intakeIds.isEmpty()) {
            return 0;
        }
        List<Document_Intake__c> stuck = [
            SELECT Id
            FROM Document_Intake__c
            WHERE Id IN :intakeIds AND Status__c = :IntakeStatus.CLASSIFYING
            WITH USER_MODE
        ];
        for (Document_Intake__c intake : stuck) {
            intake.Status__c = IntakeStatus.NEEDS_REVIEW;
            intake.Review_Reason__c = 'Automatic allocation failed. See Last Error.';
            intake.Last_Error__c = ('Allocation job failed: ' + message).left(32768);
        }
        if (!stuck.isEmpty()) {
            Database.update(stuck, false, AccessLevel.USER_MODE);
        }
        return stuck.size();
    }
}
