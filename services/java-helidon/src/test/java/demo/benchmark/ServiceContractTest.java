package demo.benchmark;

import com.fasterxml.jackson.databind.JsonNode;
import io.helidon.webserver.WebServer;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.Locale;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

final class ServiceContractTest {
    private static final Duration TIMEOUT = Duration.ofSeconds(5);
    private static final HttpClient CLIENT = HttpClient.newBuilder()
            .connectTimeout(TIMEOUT)
            .build();

    private static WebServer server;

    @BeforeAll
    static void startServer() {
        server = WebServer.builder()
                .host("127.0.0.1")
                .port(0)
                .routing(Main::routing)
                .build()
                .start();
    }

    @AfterAll
    static void stopServer() {
        if (server != null) {
            server.stop();
        }
    }

    @Test
    void getHealthReturnsExactBody() throws Exception {
        HttpResponse<String> response = CLIENT.send(
                HttpRequest.newBuilder(uri("/health"))
                        .timeout(TIMEOUT)
                        .GET()
                        .build(),
                HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));

        assertEquals(200, response.statusCode());
        assertEquals("{\"status\":\"ok\"}", response.body());
        assertJsonContentType(response);
    }

    @Test
    void headHealthReturnsSuccessWithoutBody() throws Exception {
        HttpResponse<String> response = CLIENT.send(
                HttpRequest.newBuilder(uri("/health"))
                        .timeout(TIMEOUT)
                        .method("HEAD", HttpRequest.BodyPublishers.noBody())
                        .build(),
                HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));

        assertEquals(200, response.statusCode());
        assertEquals("", response.body());
        assertJsonContentType(response);
    }

    @Test
    void postWorkAcceptsValidJsonWithCharsetContentType() throws Exception {
        WorkRequest request = new WorkRequest("svc-1", 128, 42, 1);
        String body = "{\"requestId\":\"svc-1\",\"payloadSize\":128,\"seed\":42,\"extraWork\":1}";

        HttpResponse<String> response = post(body, "application/json; charset=utf-8");

        assertEquals(200, response.statusCode());
        assertJsonContentType(response);

        JsonNode json = JsonSupport.readTreeStrict(response.body());
        assertEquals(true, json.get("ok").booleanValue());
        assertEquals(request.requestId(), json.get("requestId").asText());
        assertEquals(request.payloadSize(), json.get("payloadSize").asInt());
        assertEquals(request.extraWork(), json.get("extraWork").asInt());
        assertEquals(WorkComputer.computeChecksum(request), json.get("checksum").asText());
    }

    @Test
    void postWorkRejectsMissingOrUnsupportedContentType() throws Exception {
        String validBody = "{\"requestId\":\"svc-unsupported\",\"payloadSize\":1,\"seed\":1,\"extraWork\":0}";

        HttpResponse<String> missing = CLIENT.send(
                HttpRequest.newBuilder(uri("/work"))
                        .timeout(TIMEOUT)
                        .POST(HttpRequest.BodyPublishers.ofString(validBody, StandardCharsets.UTF_8))
                        .build(),
                HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        assertEquals(415, missing.statusCode());
        assertErrorCode(missing, "unsupported_media_type");

        HttpResponse<String> text = post(validBody, "text/plain");
        assertEquals(415, text.statusCode());
        assertErrorCode(text, "unsupported_media_type");
    }

    @Test
    void postWorkRejectsInvalidJsonAndInvalidFields() throws Exception {
        List<String> badBodies = List.of(
                "{",
                "[]",
                "{\"requestId\":\"svc-unknown\",\"payloadSize\":1,\"seed\":1,\"extraWork\":0,\"unexpected\":true}",
                "{\"requestId\":\"a\",\"requestId\":\"b\",\"payloadSize\":1,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"svc-quoted\",\"payloadSize\":\"1\",\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"svc-float\",\"payloadSize\":1.5,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"svc-bool\",\"payloadSize\":1,\"seed\":true,\"extraWork\":0}",
                "{\"requestId\":\"svc-null\",\"payloadSize\":1,\"seed\":1,\"extraWork\":null}",
                "{\"payloadSize\":1,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"\",\"payloadSize\":1,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"svc-too-large\",\"payloadSize\":131073,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"svc-bad-extra\",\"payloadSize\":1,\"seed\":1,\"extraWork\":101}"
        );

        for (String body : badBodies) {
            HttpResponse<String> response = post(body, "application/json");
            assertEquals(400, response.statusCode(), "body should be rejected: " + body);
            assertErrorCode(response, "invalid_request");
        }
    }

    @Test
    void postWorkRejectsDecodedBodiesOverLimit() throws Exception {
        String validBody = "{\"requestId\":\"svc-limit\",\"payloadSize\":1,\"seed\":1,\"extraWork\":0}";
        int bytes = validBody.getBytes(StandardCharsets.UTF_8).length;
        String oversized = validBody + " ".repeat(WorkValidator.BODY_LIMIT_BYTES + 1 - bytes);

        HttpResponse<String> response = post(oversized, "application/json");

        assertEquals(413, response.statusCode());
        assertErrorCode(response, "body_too_large");
    }

    @Test
    void unknownRouteReturnsJsonError() throws Exception {
        HttpResponse<String> response = CLIENT.send(
                HttpRequest.newBuilder(uri("/does-not-exist"))
                        .timeout(TIMEOUT)
                        .GET()
                        .build(),
                HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));

        assertEquals(404, response.statusCode());
        assertErrorCode(response, "not_found");
    }

    private static HttpResponse<String> post(String body, String contentType) throws Exception {
        return CLIENT.send(
                HttpRequest.newBuilder(uri("/work"))
                        .timeout(TIMEOUT)
                        .header("Content-Type", contentType)
                        .POST(HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8))
                        .build(),
                HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
    }

    private static URI uri(String path) {
        return URI.create("http://127.0.0.1:" + server.port() + path);
    }

    private static void assertJsonContentType(HttpResponse<String> response) {
        String contentType = response.headers().firstValue("content-type").orElse("");
        assertTrue(contentType.toLowerCase(Locale.ROOT).startsWith("application/json"),
                "expected application/json content-type but got: " + contentType);
    }

    private static void assertErrorCode(HttpResponse<String> response, String expectedCode) {
        assertJsonContentType(response);
        JsonNode json = JsonSupport.readTreeStrict(response.body());
        assertEquals(false, json.get("ok").booleanValue());
        assertEquals(expectedCode, json.get("error").get("code").asText());
        assertTrue(json.get("error").get("message").isTextual());
    }
}
