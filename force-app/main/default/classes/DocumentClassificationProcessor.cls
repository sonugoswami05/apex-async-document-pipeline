/**
 * Classifies a small list of intakes: loads their files, calls the classifier once per record and
 * writes every outcome back to the record (classified, retry scheduled, sent to review or failed).
 *
 * Shared by DocumentClassificationBatch (first attempts) and DocumentRetryQueueable (retries).
 * All callouts happen before any DML, because Apex does not allow a callout once the transaction
 * has uncommitted work.
 */
public with sharing class DocumentClassificationProcessor {
    /**
     * Files above this size go to manual review instead of being sent. It keeps a 5-record chunk
     * inside the 12 MB async heap limit (see DocumentClassificationBatch for the math).
     */
    public static final Integer MAX_FILE_BYTES = 1000000;

    private static final Integer LONG_TEXT_LIMIT = 32768;

    private final DocumentClassifierService classifier = new DocumentClassifierService();
    /** Set at the start of process(); one timestamp per run keeps errors and retry times consistent. */
    private Datetime runStartedAt;
    private List<String> candidateTypes;

    /** Per-call result. Counters feed the batch summary; Id sets drive the next step. */
    public class Outcome {
        public Integer processed = 0;
        public Set<Id> classifiedIds = new Set<Id>();
        public Set<Id> retryIds = new Set<Id>();
        public Set<Id> reviewIds = new Set<Id>();
        public Set<Id> failedIds = new Set<Id>();
        public List<String> saveErrors = new List<String>();
        /** Records whose result and fallback update both failed. Callers must not loop on them. */
        public Set<Id> unsavedIds = new Set<Id>();
    }

    public Outcome process(List<Document_Intake__c> intakes) {
        Outcome outcome = new Outcome();
        if (intakes == null || intakes.isEmpty()) {
            return outcome;
        }

        Map<Id, ContentVersion> versionsByDocument = IntakeFiles.latestVersions(intakes);
        Map<Id, ContentVersion> fileData = IntakeFiles.bodiesUnder(versionsByDocument.values(), MAX_FILE_BYTES);
        candidateTypes = DocumentTypes.values();
        runStartedAt = Datetime.now();
        List<Document_Intake__c> changes = new List<Document_Intake__c>();

        for (Document_Intake__c intake : intakes) {
            outcome.processed++;
            Document_Intake__c change = new Document_Intake__c(Id = intake.Id);
            ContentVersion version = versionsByDocument.get(IntakeFiles.toId(intake.Content_Document_Id__c));

            try {
                if (version == null) {
                    change.Attempt_Count__c = currentAttempts(intake) + 1;
                    throw new DocumentClassifierService.ClassifierRequestException(
                        'File ' + intake.Content_Document_Id__c + ' was not found or is not visible to the running user.'
                    );
                }
                if (version.ContentSize > MAX_FILE_BYTES) {
                    sendToReview(change, version);
                    outcome.reviewIds.add(intake.Id);
                } else {
                    change.Attempt_Count__c = currentAttempts(intake) + 1;
                    ContentVersion withData = fileData.get(version.Id);
                    DocumentClassifierService.ClassificationResult result = classifier.classify(
                        buildRequest(intake, version, withData == null ? null : withData.VersionData)
                    );
                    markClassified(change, result);
                    outcome.classifiedIds.add(intake.Id);
                }
            } catch (DocumentClassifierService.ClassifierException e) {
                markFailedAttempt(change, e, outcome);
            }
            changes.add(change);
        }

        save(changes, outcome);
        return outcome;
    }

    // ---------------------------------------------------------------------------------------
    // Building requests and applying outcomes
    // ---------------------------------------------------------------------------------------

    private DocumentClassifierService.ClassifyRequest buildRequest(
        Document_Intake__c intake, ContentVersion version, Blob data
    ) {
        DocumentClassifierService.ClassifyRequest request = new DocumentClassifierService.ClassifyRequest();
        request.documentId = intake.Id;
        request.fileName = String.isNotBlank(intake.File_Name__c) ? intake.File_Name__c : version.Title;
        request.fileExtension = version.FileExtension;
        request.contentBase64 = data == null ? null : EncodingUtil.base64Encode(data);
        request.candidateTypes = candidateTypes;
        return request;
    }

    private static void markClassified(Document_Intake__c change, DocumentClassifierService.ClassificationResult result) {
        change.Status__c = IntakeStatus.CLASSIFYING;
        change.Suggested_Type__c = result.documentType == null ? null : result.documentType.left(80);
        change.Confidence__c = result.confidencePercent;
        change.Next_Attempt_At__c = null;
        change.Review_Reason__c = null;
    }

    private static void sendToReview(Document_Intake__c change, ContentVersion version) {
        change.Status__c = IntakeStatus.NEEDS_REVIEW;
        change.Review_Reason__c = 'File is ' + (version.ContentSize / 1000) + ' KB. Files over '
            + (MAX_FILE_BYTES / 1000) + ' KB are not sent for automatic classification.';
    }

    /** change.Attempt_Count__c already holds the number of the attempt that just failed. */
    private void markFailedAttempt(
        Document_Intake__c change, DocumentClassifierService.ClassifierException error, Outcome outcome
    ) {
        Integer attempt = change.Attempt_Count__c.intValue();
        change.Last_Error__c = ('[Attempt ' + attempt + ', ' + runStartedAt.formatGmt('yyyy-MM-dd HH:mm:ss') + ' GMT] '
            + error.getTypeName() + ': ' + error.getMessage()).left(LONG_TEXT_LIMIT);

        if (error.isRetryable() && RetryPolicy.canRetry(attempt)) {
            change.Status__c = IntakeStatus.QUEUED;
            change.Next_Attempt_At__c = runStartedAt.addMinutes(RetryPolicy.delayMinutes(attempt));
            outcome.retryIds.add(change.Id);
        } else {
            change.Status__c = IntakeStatus.FAILED;
            change.Next_Attempt_At__c = null;
            outcome.failedIds.add(change.Id);
        }
    }

    /**
     * Partial-success save. A record that cannot be saved (deleted, locked, blocked by a validation
     * rule) gets a second, minimal update that only marks it Failed with the reason. If even that
     * fails, the error stays in outcome.saveErrors for the run summary. Nothing is dropped silently.
     */
    private static void save(List<Document_Intake__c> changes, Outcome outcome) {
        List<Database.SaveResult> results = Database.update(changes, false, AccessLevel.USER_MODE);
        List<Document_Intake__c> fallbacks = new List<Document_Intake__c>();

        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                continue;
            }
            Id intakeId = changes[i].Id;
            String message = describe(results[i].getErrors());
            outcome.saveErrors.add(intakeId + ': ' + message);
            forget(outcome, intakeId);
            fallbacks.add(new Document_Intake__c(
                Id = intakeId,
                Status__c = IntakeStatus.FAILED,
                Last_Error__c = ('Could not save the classification result: ' + message).left(LONG_TEXT_LIMIT)
            ));
        }

        if (fallbacks.isEmpty()) {
            return;
        }
        List<Database.SaveResult> fallbackResults = Database.update(fallbacks, false, AccessLevel.USER_MODE);
        for (Integer i = 0; i < fallbackResults.size(); i++) {
            if (fallbackResults[i].isSuccess()) {
                outcome.failedIds.add(fallbacks[i].Id);
            } else {
                outcome.unsavedIds.add(fallbacks[i].Id);
            }
        }
    }

    private static void forget(Outcome outcome, Id intakeId) {
        outcome.classifiedIds.remove(intakeId);
        outcome.retryIds.remove(intakeId);
        outcome.reviewIds.remove(intakeId);
        outcome.failedIds.remove(intakeId);
    }

    private static String describe(List<Database.Error> errors) {
        List<String> parts = new List<String>();
        for (Database.Error error : errors) {
            parts.add(error.getStatusCode() + ' ' + error.getMessage());
        }
        return String.join(parts, '; ');
    }

    private static Integer currentAttempts(Document_Intake__c intake) {
        return intake.Attempt_Count__c == null ? 0 : intake.Attempt_Count__c.intValue();
    }
}
