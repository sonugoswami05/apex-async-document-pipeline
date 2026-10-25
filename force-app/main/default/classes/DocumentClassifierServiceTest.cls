@IsTest
private class DocumentClassifierServiceTest {
    private static DocumentClassifierService.ClassifyRequest sampleRequest() {
        DocumentClassifierService.ClassifyRequest request = new DocumentClassifierService.ClassifyRequest();
        request.documentId = 'intake-under-test';
        request.fileName = 'statement.pdf';
        request.fileExtension = 'pdf';
        request.contentBase64 = EncodingUtil.base64Encode(Blob.valueOf('sample'));
        request.candidateTypes = DocumentTypes.values();
        return request;
    }

    private static DocumentClassifierService.ClassifierException classifyExpectingFailure(ClassifierHttpMock mock) {
        Test.setMock(HttpCalloutMock.class, mock);
        try {
            new DocumentClassifierService().classify(sampleRequest());
        } catch (DocumentClassifierService.ClassifierException e) {
            return e;
        }
        Assert.fail('Expected a ClassifierException');
        return null;
    }

    @IsTest
    static void successReturnsNormalizedTypeAndPercent() {
        ClassifierHttpMock mock = ClassifierHttpMock.success('bank_statement', 0.934);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        DocumentClassifierService.ClassificationResult result = new DocumentClassifierService().classify(sampleRequest());
        Test.stopTest();

        Assert.areEqual('Bank Statement', result.documentType, 'Type should map onto the picklist value');
        Assert.isTrue(result.confidencePercent == 93.4, 'Confidence should be stored as a percent, got ' + result.confidencePercent);
        Assert.areEqual('test-model-1', result.modelVersion, 'Model version should pass through');
        Assert.areEqual(1, mock.calls, 'Exactly one callout per document');
        Assert.areEqual(DocumentClassifierService.ENDPOINT, mock.lastRequest.getEndpoint(), 'Must use the named credential');
        Assert.areEqual('POST', mock.lastRequest.getMethod(), 'Classify is a POST');
        Assert.areEqual('application/json', mock.lastRequest.getHeader('Content-Type'), 'JSON body expected');
        Assert.isTrue(mock.lastRequest.getBody().contains('"candidateTypes"'), 'Candidate types should be sent');
        Assert.isFalse(mock.lastRequest.getBody().contains('Authorization'), 'No credentials in the body');
    }

    @IsTest
    static void unknownTypeIsKeptForTheReviewer() {
        Test.setMock(HttpCalloutMock.class, ClassifierHttpMock.success('  Utility Bill ', 0.91));
        DocumentClassifierService.ClassificationResult result = new DocumentClassifierService().classify(sampleRequest());
        Assert.areEqual('Utility Bill', result.documentType, 'Unknown types are trimmed, not dropped');
    }

    @IsTest
    static void serverErrorIsRetryable() {
        DocumentClassifierService.ClassifierException error = classifyExpectingFailure(
            ClassifierHttpMock.status(500, '{"error":"internal"}')
        );
        Assert.isInstanceOfType(error, DocumentClassifierService.ClassifierUnavailableException.class, 'HTTP 500 is unavailable');
        Assert.isTrue(error.isRetryable(), 'HTTP 500 should be retried');
        Assert.isTrue(error.getMessage().contains('HTTP 500'), 'Status code should be in the message');
    }

    @IsTest
    static void rateLimitIsRetryable() {
        DocumentClassifierService.ClassifierException error = classifyExpectingFailure(ClassifierHttpMock.status(429, 'slow down'));
        Assert.isTrue(error.isRetryable(), 'HTTP 429 should be retried');
    }

    @IsTest
    static void timeoutIsRetryable() {
        DocumentClassifierService.ClassifierException error = classifyExpectingFailure(ClassifierHttpMock.timeout());
        Assert.isInstanceOfType(error, DocumentClassifierService.ClassifierTimeoutException.class, 'Timeouts get their own type');
        Assert.isTrue(error.isRetryable(), 'Timeouts should be retried');
        Assert.isTrue(error.getMessage().contains('did not respond within 20s'), 'Message should name the timeout');
        Assert.isNotNull(error.getCause(), 'Original CalloutException should be kept as the cause');
    }

    @IsTest
    static void networkFailureIsRetryable() {
        DocumentClassifierService.ClassifierException error = classifyExpectingFailure(ClassifierHttpMock.unreachable());
        Assert.isInstanceOfType(error, DocumentClassifierService.ClassifierUnavailableException.class, 'Network failure is unavailable');
        Assert.isTrue(error.isRetryable(), 'Network failures should be retried');
    }

    @IsTest
    static void badRequestIsNotRetryable() {
        DocumentClassifierService.ClassifierException error = classifyExpectingFailure(
            ClassifierHttpMock.status(400, '{"error":"unsupported file"}')
        );
        Assert.isInstanceOfType(error, DocumentClassifierService.ClassifierRequestException.class, 'HTTP 400 is a request error');
        Assert.isFalse(error.isRetryable(), 'HTTP 400 would fail the same way again');
    }

    @IsTest
    static void malformedJsonIsAResponseError() {
        DocumentClassifierService.ClassifierException error = classifyExpectingFailure(ClassifierHttpMock.status(200, 'not json'));
        Assert.isInstanceOfType(error, DocumentClassifierService.ClassifierResponseException.class, 'Bad JSON is a response error');
        Assert.isFalse(error.isRetryable(), 'Bad JSON is not retried');
    }

    @IsTest
    static void emptyBodyIsAResponseError() {
        DocumentClassifierService.ClassifierException error = classifyExpectingFailure(ClassifierHttpMock.status(200, ''));
        Assert.isInstanceOfType(error, DocumentClassifierService.ClassifierResponseException.class, 'Empty body is a response error');
    }

    @IsTest
    static void confidenceOutsideRangeIsAResponseError() {
        DocumentClassifierService.ClassifierException error = classifyExpectingFailure(ClassifierHttpMock.success('Pay Stub', 1.5));
        Assert.isInstanceOfType(error, DocumentClassifierService.ClassifierResponseException.class, 'Confidence must be 0..1');
    }

    @IsTest
    static void missingTypeIsAResponseError() {
        DocumentClassifierService.ClassifierException error = classifyExpectingFailure(
            ClassifierHttpMock.status(200, '{"confidence":0.9}')
        );
        Assert.isInstanceOfType(error, DocumentClassifierService.ClassifierResponseException.class, 'documentType is required');
    }

    @IsTest
    static void documentTypesNormalize() {
        Assert.areEqual('Photo ID', DocumentTypes.normalize('  photo   id '), 'Case and spacing are ignored');
        Assert.areEqual('Proof of Address', DocumentTypes.normalize('PROOF_OF_ADDRESS'), 'Underscores become spaces');
        Assert.isNull(DocumentTypes.normalize('   '), 'Blank stays blank');
        Assert.isTrue(DocumentTypes.values().contains('Bank Statement'), 'Picklist values are offered to the classifier');
    }
}
