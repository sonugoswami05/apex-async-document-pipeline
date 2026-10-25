/**
 * Calls the external classification service through the Doc_Classifier named credential.
 * The endpoint host and the API key live in the named and external credential, never in code.
 *
 * Every failure is raised as a ClassifierException subtype, so callers need one catch block and a
 * single isRetryable() check:
 *
 *   ClassifierTimeoutException      read or connect timeout              retryable
 *   ClassifierUnavailableException  HTTP 429 or 5xx, network failure     retryable
 *   ClassifierRequestException      HTTP 4xx, missing file               not retryable
 *   ClassifierResponseException     body is not the expected shape       not retryable
 */
public with sharing class DocumentClassifierService {
    public static final String ENDPOINT = 'callout:Doc_Classifier/v1/classify';

    /** Per-callout timeout. The batch scope size is derived from it; see DocumentClassificationBatch. */
    public static final Integer TIMEOUT_MS = 20000;

    private static final Integer ERROR_SNIPPET_LENGTH = 500;

    /** Sends one document and returns the suggested type with confidence as a percent (0 to 100). */
    public ClassificationResult classify(ClassifyRequest payload) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint(ENDPOINT);
        request.setMethod('POST');
        request.setTimeout(TIMEOUT_MS);
        request.setHeader('Content-Type', 'application/json');
        request.setHeader('Accept', 'application/json');
        request.setBody(JSON.serialize(payload, true));

        HttpResponse response;
        try {
            response = new Http().send(request);
        } catch (CalloutException e) {
            throw translate(e);
        }
        return parse(response);
    }

    @TestVisible
    private static ClassifierException translate(CalloutException e) {
        String message = String.valueOf(e.getMessage());
        if (message.containsIgnoreCase('timed out') || message.containsIgnoreCase('timeout')) {
            return new ClassifierTimeoutException(
                'Classifier did not respond within ' + (TIMEOUT_MS / 1000) + 's: ' + message, e
            );
        }
        return new ClassifierUnavailableException('Could not reach the classifier: ' + message, e);
    }

    private static ClassificationResult parse(HttpResponse response) {
        String body = response.getBody();
        checkStatus(response.getStatusCode(), body);
        ClassifyResponse parsed = deserialize(body);
        validate(parsed, body);
        return new ClassificationResult(
            DocumentTypes.normalize(parsed.documentType),
            (parsed.confidence * 100).setScale(2),
            parsed.modelVersion
        );
    }

    /** Maps non-2xx statuses to the right exception type. */
    private static void checkStatus(Integer status, String body) {
        if (status == 429 || status >= 500) {
            throw new ClassifierUnavailableException('Classifier returned HTTP ' + status + ': ' + snippet(body));
        }
        if (status < 200 || status >= 300) {
            throw new ClassifierRequestException('Classifier rejected the request with HTTP ' + status + ': ' + snippet(body));
        }
        if (String.isBlank(body)) {
            throw new ClassifierResponseException('Classifier returned HTTP ' + status + ' with an empty body.');
        }
    }

    private static ClassifyResponse deserialize(String body) {
        try {
            return (ClassifyResponse) JSON.deserialize(body, ClassifyResponse.class);
        } catch (JSONException e) {
            throw new ClassifierResponseException('Classifier response is not valid JSON: ' + e.getMessage(), e);
        } catch (TypeException e) {
            throw new ClassifierResponseException('Classifier response has an unexpected shape: ' + e.getMessage(), e);
        }
    }

    private static void validate(ClassifyResponse parsed, String body) {
        Boolean hasType = parsed != null && String.isNotBlank(parsed.documentType);
        Boolean confidenceInRange = parsed != null && parsed.confidence != null
            && parsed.confidence >= 0 && parsed.confidence <= 1;
        if (!hasType || !confidenceInRange) {
            throw new ClassifierResponseException(
                'Classifier response needs documentType and a confidence between 0 and 1: ' + snippet(body)
            );
        }
    }

    private static String snippet(String body) {
        return body == null ? '' : body.abbreviate(ERROR_SNIPPET_LENGTH);
    }

    // ---------------------------------------------------------------------------------------
    // Request and response DTOs. Field names match the service's JSON contract.
    // ---------------------------------------------------------------------------------------

    /** POST /v1/classify request body. */
    public class ClassifyRequest {
        public String documentId;
        public String fileName;
        public String fileExtension;
        public String contentBase64;
        public List<String> candidateTypes;
    }

    /** POST /v1/classify response body. confidence is a fraction from 0 to 1. */
    public class ClassifyResponse {
        public String documentType;
        public Decimal confidence;
        public String modelVersion;
    }

    /** What the rest of the pipeline works with: a normalized type and a percent. */
    public class ClassificationResult {
        public final String documentType;
        public final Decimal confidencePercent;
        public final String modelVersion;

        public ClassificationResult(String documentType, Decimal confidencePercent, String modelVersion) {
            this.documentType = documentType;
            this.confidencePercent = confidencePercent;
            this.modelVersion = modelVersion;
        }
    }

    // ---------------------------------------------------------------------------------------
    // Typed exceptions
    // ---------------------------------------------------------------------------------------

    /** Base type. Not retryable unless a subtype says otherwise. */
    public virtual class ClassifierException extends Exception {
        public virtual Boolean isRetryable() {
            return false;
        }
    }

    /** The service did not answer within TIMEOUT_MS. */
    public class ClassifierTimeoutException extends ClassifierException {
        public override Boolean isRetryable() {
            return true;
        }
    }

    /** HTTP 429, HTTP 5xx or a network failure. Usually temporary. */
    public class ClassifierUnavailableException extends ClassifierException {
        public override Boolean isRetryable() {
            return true;
        }
    }

    /** HTTP 4xx or a file that cannot be sent. Retrying would fail the same way. */
    public class ClassifierRequestException extends ClassifierException {
    }

    /** HTTP 2xx with a body we cannot use. */
    public class ClassifierResponseException extends ClassifierException {
    }
}
