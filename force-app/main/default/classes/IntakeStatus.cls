/**
 * Status values for Document_Intake__c.Status__c.
 * Kept in one place so a typo fails at compile time instead of silently matching nothing in a query.
 */
public inherited sharing class IntakeStatus {
    public static final String QUEUED = 'Queued';
    public static final String UPLOADING = 'Uploading';
    public static final String CLASSIFYING = 'Classifying';
    public static final String ALLOCATED = 'Allocated';
    public static final String NEEDS_REVIEW = 'Needs_Review';
    public static final String FAILED = 'Failed';

    /** Checklist_Item__c.Status__c values used by allocation. */
    public static final String ITEM_OPEN = 'Open';
    public static final String ITEM_RECEIVED = 'Received';
}
