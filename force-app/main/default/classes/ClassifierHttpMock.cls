/**
 * Configurable HttpCalloutMock for the classification service:
 * success, any HTTP status, a timeout, or a network failure.
 */
@IsTest
public class ClassifierHttpMock implements HttpCalloutMock {
    public Integer statusCode = 200;
    public String body = '';
    public String calloutError;
    public Integer calls = 0;
    public HttpRequest lastRequest;

    public static ClassifierHttpMock success(String documentType, Decimal confidence) {
        ClassifierHttpMock mock = new ClassifierHttpMock();
        mock.body = JSON.serialize(new Map<String, Object>{
            'documentType' => documentType,
            'confidence' => confidence,
            'modelVersion' => 'test-model-1'
        });
        return mock;
    }

    public static ClassifierHttpMock status(Integer statusCode, String body) {
        ClassifierHttpMock mock = new ClassifierHttpMock();
        mock.statusCode = statusCode;
        mock.body = body;
        return mock;
    }

    /** Same message the platform uses when the read timeout expires. */
    public static ClassifierHttpMock timeout() {
        ClassifierHttpMock mock = new ClassifierHttpMock();
        mock.calloutError = 'Read timed out';
        return mock;
    }

    public static ClassifierHttpMock unreachable() {
        ClassifierHttpMock mock = new ClassifierHttpMock();
        mock.calloutError = 'Unable to tunnel through proxy. Proxy returns "HTTP/1.1 503 Service Unavailable"';
        return mock;
    }

    public HttpResponse respond(HttpRequest request) {
        calls++;
        lastRequest = request;
        if (calloutError != null) {
            throw new CalloutException(calloutError);
        }
        HttpResponse response = new HttpResponse();
        response.setStatusCode(statusCode);
        response.setHeader('Content-Type', 'application/json');
        response.setBody(body == null ? '' : body);
        return response;
    }
}
