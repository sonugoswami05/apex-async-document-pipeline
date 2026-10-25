/**
 * Capped exponential backoff for retryable classifier failures.
 *
 * With the default settings (base 1 minute, 4 attempts) a document that keeps timing out is tried
 * at roughly t0, t0 + 1, t0 + 3 and t0 + 7 minutes, then marked Failed with the last error kept.
 */
public inherited sharing class RetryPolicy {
    /** System.enqueueJob accepts a delay of 0 to 10 minutes, so that is the ceiling. */
    public static final Integer MAX_DELAY_MINUTES = 10;

    /** True when another attempt is allowed after attemptsMade attempts. */
    public static Boolean canRetry(Integer attemptsMade) {
        return attemptsMade != null && attemptsMade < PipelineSettings.maxAttempts();
    }

    /**
     * Delay before the retry that follows the given failed attempt: base * 2^(attempt - 1), capped.
     * Attempt 1 waits base, attempt 2 waits 2 x base, attempt 3 waits 4 x base, and so on.
     */
    public static Integer delayMinutes(Integer failedAttempt) {
        Integer exponent = Math.max(0, (failedAttempt == null ? 1 : failedAttempt) - 1);
        Integer delay = PipelineSettings.baseBackoffMinutes();
        // Stop doubling once past the cap so a large attempt number can never overflow.
        for (Integer i = 0; i < exponent && delay < MAX_DELAY_MINUTES; i++) {
            delay *= 2;
        }
        return Math.min(delay, MAX_DELAY_MINUTES);
    }
}
