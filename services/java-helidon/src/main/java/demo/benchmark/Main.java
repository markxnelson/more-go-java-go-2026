package demo.benchmark;

import io.helidon.http.HeaderNames;
import io.helidon.http.Status;
import io.helidon.webserver.WebServer;
import io.helidon.webserver.http.HttpRouting;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

public final class Main {
    private static final String JSON = "application/json";
    private static final boolean TRAINING_SHUTDOWN_ENABLED =
            "true".equalsIgnoreCase(System.getenv().getOrDefault("BENCHMARK_TRAINING_SHUTDOWN", ""));

    private Main() {
    }

    public static void main(String[] args) throws InterruptedException {
        int port = Integer.parseInt(System.getenv().getOrDefault("JAVA_PORT", "18082"));

        WebServer server = WebServer.builder()
                .host("127.0.0.1")
                .port(port)
                .routing(Main::routing)
                .build()
                .start();

        System.out.println("java-helidon listening on 127.0.0.1:" + server.port());
        Thread.currentThread().join();
    }

    static void routing(HttpRouting.Builder routing) {
        routing.get("/health", Main::getHealth);
        routing.head("/health", Main::headHealth);
        routing.post("/work", Main::postWork);

        if (TRAINING_SHUTDOWN_ENABLED) {
            routing.post("/__benchmark/shutdown", Main::postTrainingShutdown);
        }

        routing.any(Main::notFound);
    }

    static void getHealth(ServerRequest request, ServerResponse response) {
        response.header(HeaderNames.CONTENT_TYPE, JSON);
        response.status(Status.OK_200);
        response.send("{\"status\":\"ok\"}");
    }

    static void headHealth(ServerRequest request, ServerResponse response) {
        response.header(HeaderNames.CONTENT_TYPE, JSON);
        response.status(Status.OK_200);
        response.send();
    }

    static void postWork(ServerRequest request, ServerResponse response) {
        String contentType = request.headers().first(HeaderNames.CONTENT_TYPE).orElse("");
        if (!isJsonContentType(contentType)) {
            sendError(response,
                    Status.UNSUPPORTED_MEDIA_TYPE_415,
                    "unsupported_media_type",
                    "content-type must be application/json");
            return;
        }

        try {
            byte[] bodyBytes = readLimitedRequestBody(request);
            String body = decodeUtf8(bodyBytes);

            WorkRequest workRequest = WorkValidator.decodeAndValidate(body);
            WorkResponse workResponse = new WorkResponse(
                    workRequest.requestId(),
                    workRequest.payloadSize(),
                    workRequest.extraWork(),
                    WorkComputer.computeChecksum(workRequest),
                    true);

            response.header(HeaderNames.CONTENT_TYPE, JSON);
            response.status(Status.OK_200);
            response.send(JsonSupport.write(workResponse));
        } catch (BodyTooLargeException e) {
            sendError(response,
                    Status.REQUEST_ENTITY_TOO_LARGE_413,
                    "body_too_large",
                    "decoded body exceeds limit");
        } catch (CharacterCodingException e) {
            sendError(response,
                    Status.BAD_REQUEST_400,
                    "invalid_request",
                    "request body must be valid utf-8");
        } catch (IOException e) {
            sendError(response,
                    Status.BAD_REQUEST_400,
                    "invalid_request",
                    "request body read failed");
        } catch (IllegalArgumentException e) {
            sendError(response,
                    Status.BAD_REQUEST_400,
                    "invalid_request",
                    e.getMessage());
        }
    }

    static void postTrainingShutdown(ServerRequest request, ServerResponse response) {
        response.header(HeaderNames.CONTENT_TYPE, JSON);
        response.status(Status.OK_200);
        response.send("{\"status\":\"shutting_down\"}");

        Thread shutdownThread = new Thread(() -> {
            try {
                Thread.sleep(100);
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
            System.exit(0);
        }, "benchmark-training-shutdown");

        shutdownThread.setDaemon(false);
        shutdownThread.start();
    }

    static void notFound(ServerRequest request, ServerResponse response) {
        sendError(response, Status.NOT_FOUND_404, "not_found", "route not found");
    }

    static void sendError(ServerResponse response, Status status, String code, String message) {
        response.header(HeaderNames.CONTENT_TYPE, JSON);
        response.status(status);
        response.send(JsonSupport.write(new ErrorResponse(false, new ErrorResponse.ErrorInfo(code, message))));
    }

    private static boolean isJsonContentType(String contentType) {
        int semicolon = contentType.indexOf(';');
        String mediaType = semicolon >= 0 ? contentType.substring(0, semicolon) : contentType;
        return JSON.equals(mediaType.trim().toLowerCase(Locale.ROOT));
    }

    private static byte[] readLimitedRequestBody(ServerRequest request) throws IOException {
        int limitPlusOne = WorkValidator.BODY_LIMIT_BYTES + 1;
        byte[] buffer = new byte[512];

        try (InputStream input = request.content().inputStream();
             ByteArrayOutputStream output = new ByteArrayOutputStream(Math.min(limitPlusOne, buffer.length))) {
            int total = 0;

            while (total < limitPlusOne) {
                int maxRead = Math.min(buffer.length, limitPlusOne - total);
                int read = input.read(buffer, 0, maxRead);
                if (read == -1) {
                    return output.toByteArray();
                }

                output.write(buffer, 0, read);
                total += read;

                if (total > WorkValidator.BODY_LIMIT_BYTES) {
                    throw new BodyTooLargeException("body too large");
                }
            }

            throw new BodyTooLargeException("body too large");
        }
    }

    private static String decodeUtf8(byte[] bytes) throws CharacterCodingException {
        return StandardCharsets.UTF_8
                .newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString();
    }
}
