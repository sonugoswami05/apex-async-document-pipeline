/** Covers PipelineSettings, RetryPolicy and AsyncJobs. */
@IsTest
private class PipelineSupportTest {
    @IsTest
    static void settingsComeFromTheDefaultRecord() {
        Pipeline_Setting__mdt deployed = Pipeline_Setting__mdt.getInstance(PipelineSettings.RECORD_NAME);
        Assert.isNotNull(deployed, 'Default record ships with the source');
        Assert.areEqual(deployed.Confidence_Threshold__c, PipelineSettings.confidenceThreshold(), 'Threshold read from CMDT');
        Assert.areEqual(deployed.Max_Attempts__c.intValue(), PipelineSettings.maxAttempts(), 'Max attempts read from CMDT');
        Assert.areEqual(deployed.Base_Backoff_Minutes__c.intValue(), PipelineSettings.baseBackoffMinutes(), 'Backoff read from CMDT');
    }

    @IsTest
    static void blankSettingsFallBackToDefaults() {
        PipelineSettings.current = new Pipeline_Setting__mdt();
        Assert.areEqual(PipelineSettings.DEFAULT_CONFIDENCE_THRESHOLD, PipelineSettings.confidenceThreshold(), 'Fallback threshold');
        Assert.areEqual(PipelineSettings.DEFAULT_MAX_ATTEMPTS, PipelineSettings.maxAttempts(), 'Fallback attempts');
        Assert.areEqual(PipelineSettings.DEFAULT_BASE_BACKOFF_MINUTES, PipelineSettings.baseBackoffMinutes(), 'Fallback backoff');
    }

    @IsTest
    static void backoffDoublesAndCaps() {
        TestDataFactory.useSettings(80, 6, 1);
        Assert.areEqual(1, RetryPolicy.delayMinutes(1), 'Attempt 1 waits base');
        Assert.areEqual(2, RetryPolicy.delayMinutes(2), 'Attempt 2 waits 2 x base');
        Assert.areEqual(4, RetryPolicy.delayMinutes(3), 'Attempt 3 waits 4 x base');
        Assert.areEqual(8, RetryPolicy.delayMinutes(4), 'Attempt 4 waits 8 x base');
        Assert.areEqual(10, RetryPolicy.delayMinutes(5), 'Capped at the enqueueJob maximum');
        Assert.areEqual(10, RetryPolicy.delayMinutes(60), 'Large attempts do not overflow');
        Assert.areEqual(1, RetryPolicy.delayMinutes(null), 'Null treated as the first attempt');

        TestDataFactory.useSettings(80, 6, 3);
        Assert.areEqual(6, RetryPolicy.delayMinutes(2), 'Base is configurable');
    }

    @IsTest
    static void retriesStopAtMaxAttempts() {
        TestDataFactory.useSettings(80, 3, 1);
        Assert.isTrue(RetryPolicy.canRetry(1), 'Second attempt allowed');
        Assert.isTrue(RetryPolicy.canRetry(2), 'Third attempt allowed');
        Assert.isFalse(RetryPolicy.canRetry(3), 'No fourth attempt');
        Assert.isFalse(RetryPolicy.canRetry(null), 'Null is not retryable');
    }

    @IsTest
    static void asyncJobsEnqueuesAndClampsDelay() {
        Test.startTest();
        Id immediate = AsyncJobs.enqueue(new DocumentAllocationQueueable(new Set<Id>()), 0);
        Test.stopTest();
        Assert.isNotNull(immediate, 'Job enqueued');

        AsyncJobs.captureOnly = true;
        AsyncJobs.enqueue(new DocumentAllocationQueueable(null), 25);
        AsyncJobs.enqueue(new DocumentAllocationQueueable(null), -4);
        Assert.areEqual(new List<Integer>{ 10, 0 }, AsyncJobs.capturedDelays, 'Delay clamped to 0..10');
    }

    @IsTest
    static void asyncJobsSupportsDelayedEnqueue() {
        Test.startTest();
        Id delayed = AsyncJobs.enqueue(new DocumentAllocationQueueable(new Set<Id>()), 2);
        Test.stopTest();
        Assert.isNotNull(delayed, 'Delayed job enqueued');
    }
}
