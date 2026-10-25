/**
 * Thin seam over System.enqueueJob.
 *
 * Production code always calls enqueue(). Unit tests switch on captureOnly to assert which job
 * would run and with what delay, instead of depending on how the platform runs chained async work
 * inside a test (it does not run most of it).
 */
public inherited sharing class AsyncJobs {
    @TestVisible
    private static Boolean captureOnly = false;
    @TestVisible
    private static List<Queueable> captured = new List<Queueable>();
    @TestVisible
    private static List<Integer> capturedDelays = new List<Integer>();

    /** Enqueues the job, clamping the delay to the 0 to 10 minute range the platform accepts. */
    public static Id enqueue(Queueable job, Integer delayMinutes) {
        Integer delay = Math.max(0, Math.min(delayMinutes == null ? 0 : delayMinutes, RetryPolicy.MAX_DELAY_MINUTES));
        if (captureOnly) {
            captured.add(job);
            capturedDelays.add(delay);
            return null;
        }
        return delay > 0 ? System.enqueueJob(job, delay) : System.enqueueJob(job);
    }
}
