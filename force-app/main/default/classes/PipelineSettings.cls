/**
 * Reads Pipeline_Setting__mdt.Default. Custom metadata is cached by the platform and does not
 * count against SOQL limits when read with getInstance(), so callers can use these freely.
 * Fallback values apply only if the record is missing or a field is blank.
 */
public inherited sharing class PipelineSettings {
    public static final String RECORD_NAME = 'Default';

    @TestVisible
    private static final Decimal DEFAULT_CONFIDENCE_THRESHOLD = 80;
    @TestVisible
    private static final Integer DEFAULT_MAX_ATTEMPTS = 4;
    @TestVisible
    private static final Integer DEFAULT_BASE_BACKOFF_MINUTES = 1;

    /** Tests can assign an in-memory record here to pin the values they depend on. */
    @TestVisible
    private static Pipeline_Setting__mdt current;

    public static Pipeline_Setting__mdt get() {
        if (current == null) {
            current = Pipeline_Setting__mdt.getInstance(RECORD_NAME);
        }
        if (current == null) {
            current = new Pipeline_Setting__mdt();
        }
        return current;
    }

    /** Percent, 0 to 100. Classifications below this go to Needs_Review. */
    public static Decimal confidenceThreshold() {
        Decimal value = get().Confidence_Threshold__c;
        return value == null ? DEFAULT_CONFIDENCE_THRESHOLD : value;
    }

    /** Total attempts including the first one. */
    public static Integer maxAttempts() {
        Decimal value = get().Max_Attempts__c;
        return (value == null || value < 1) ? DEFAULT_MAX_ATTEMPTS : value.intValue();
    }

    public static Integer baseBackoffMinutes() {
        Decimal value = get().Base_Backoff_Minutes__c;
        return (value == null || value < 1) ? DEFAULT_BASE_BACKOFF_MINUTES : value.intValue();
    }
}
