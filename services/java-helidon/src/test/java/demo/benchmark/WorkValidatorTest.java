package demo.benchmark;

import org.junit.jupiter.api.Test;

import java.nio.charset.StandardCharsets;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

final class WorkValidatorTest {
    @Test
    void acceptsValidRequest() {
        WorkRequest request = WorkValidator.decodeAndValidate(
                "{\"requestId\":\"valid-1\",\"payloadSize\":128,\"seed\":42,\"extraWork\":1}");

        assertEquals("valid-1", request.requestId());
        assertEquals(128, request.payloadSize());
        assertEquals(42, request.seed());
        assertEquals(1, request.extraWork());
    }

    @Test
    void acceptsDocumentAtDecodedBodyLimit() {
        String valid = "{\"requestId\":\"limit-ok\",\"payloadSize\":1,\"seed\":1,\"extraWork\":0}";
        String padded = padToBytes(valid, WorkValidator.BODY_LIMIT_BYTES);

        WorkRequest request = WorkValidator.decodeAndValidate(padded);

        assertEquals("limit-ok", request.requestId());
        assertEquals(WorkValidator.BODY_LIMIT_BYTES, padded.getBytes(StandardCharsets.UTF_8).length);
    }

    @Test
    void acceptsBoundaryValues() {
        WorkRequest min = WorkValidator.decodeAndValidate(
                "{\"requestId\":\"min\",\"payloadSize\":0,\"seed\":0,\"extraWork\":0}");
        assertEquals(0, min.payloadSize());
        assertEquals(0, min.seed());
        assertEquals(0, min.extraWork());

        String maxRequestId = "r".repeat(128);
        WorkRequest max = WorkValidator.decodeAndValidate(
                "{\"requestId\":\"" + maxRequestId + "\",\"payloadSize\":131072,\"seed\":2147483647,\"extraWork\":100}");
        assertEquals(maxRequestId, max.requestId());
        assertEquals(131072, max.payloadSize());
        assertEquals(2147483647, max.seed());
        assertEquals(100, max.extraWork());
    }

    @Test
    void rejectsOversizedDecodedBodyBeforeJsonDecode() {
        String valid = "{\"requestId\":\"limit-too-large\",\"payloadSize\":1,\"seed\":1,\"extraWork\":0}";
        String oversized = padToBytes(valid, WorkValidator.BODY_LIMIT_BYTES + 1);

        assertThrows(BodyTooLargeException.class, () -> WorkValidator.decodeAndValidate(oversized));

        String invalidJsonButOversized = "€".repeat(1366);
        assertThrows(BodyTooLargeException.class, () -> WorkValidator.decodeAndValidate(invalidJsonButOversized));
    }

    @Test
    void rejectsInvalidJsonAndNonObjectDocuments() {
        List<String> bodies = List.of(
                "{",
                "",
                "[]",
                "null",
                "true",
                "\"string\"",
                "123",
                "{\"requestId\":\"a\",\"payloadSize\":1,\"seed\":1,\"extraWork\":0} {}"
        );

        for (String body : bodies) {
            assertThrows(RuntimeException.class, () -> WorkValidator.decodeAndValidate(body),
                    "body should be rejected: " + body);
        }
    }

    @Test
    void rejectsMissingFields() {
        List<String> bodies = List.of(
                "{\"payloadSize\":1,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"missing-payload\",\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"missing-seed\",\"payloadSize\":1,\"extraWork\":0}",
                "{\"requestId\":\"missing-extra\",\"payloadSize\":1,\"seed\":1}"
        );

        for (String body : bodies) {
            assertThrows(IllegalArgumentException.class, () -> WorkValidator.decodeAndValidate(body),
                    "body should be rejected: " + body);
        }
    }

    @Test
    void rejectsUnknownFields() {
        String body = "{\"requestId\":\"unknown\",\"payloadSize\":1,\"seed\":1,\"extraWork\":0,\"unexpected\":false}";

        assertThrows(IllegalArgumentException.class, () -> WorkValidator.decodeAndValidate(body));
    }

    @Test
    void rejectsDuplicateFields() {
        List<String> bodies = List.of(
                "{\"requestId\":\"a\",\"requestId\":\"b\",\"payloadSize\":1,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"dup-payload\",\"payloadSize\":1,\"payloadSize\":2,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"dup-seed\",\"payloadSize\":1,\"seed\":1,\"seed\":2,\"extraWork\":0}",
                "{\"requestId\":\"dup-extra\",\"payloadSize\":1,\"seed\":1,\"extraWork\":0,\"extraWork\":1}"
        );

        for (String body : bodies) {
            assertThrows(IllegalArgumentException.class, () -> WorkValidator.decodeAndValidate(body),
                    "body should be rejected: " + body);
        }
    }

    @Test
    void rejectsQuotedNumericStrings() {
        List<String> bodies = List.of(
                "{\"requestId\":\"quoted-payload\",\"payloadSize\":\"1\",\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"quoted-seed\",\"payloadSize\":1,\"seed\":\"1\",\"extraWork\":0}",
                "{\"requestId\":\"quoted-extra\",\"payloadSize\":1,\"seed\":1,\"extraWork\":\"0\"}"
        );

        for (String body : bodies) {
            assertThrows(IllegalArgumentException.class, () -> WorkValidator.decodeAndValidate(body),
                    "body should be rejected: " + body);
        }
    }

    @Test
    void rejectsWrongScalarTypes() {
        List<String> bodies = List.of(
                "{\"requestId\":1,\"payloadSize\":1,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":true,\"payloadSize\":1,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":null,\"payloadSize\":1,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":[],\"payloadSize\":1,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"bad-payload-float\",\"payloadSize\":1.5,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"bad-payload-bool\",\"payloadSize\":true,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"bad-payload-null\",\"payloadSize\":null,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"bad-seed-float\",\"payloadSize\":1,\"seed\":1.5,\"extraWork\":0}",
                "{\"requestId\":\"bad-seed-bool\",\"payloadSize\":1,\"seed\":false,\"extraWork\":0}",
                "{\"requestId\":\"bad-extra-float\",\"payloadSize\":1,\"seed\":1,\"extraWork\":1.5}",
                "{\"requestId\":\"bad-extra-object\",\"payloadSize\":1,\"seed\":1,\"extraWork\":{}}"
        );

        for (String body : bodies) {
            assertThrows(IllegalArgumentException.class, () -> WorkValidator.decodeAndValidate(body),
                    "body should be rejected: " + body);
        }
    }

    @Test
    void rejectsOutOfRangeValues() {
        List<String> bodies = List.of(
                "{\"requestId\":\"\",\"payloadSize\":1,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"" + "r".repeat(129) + "\",\"payloadSize\":1,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"payload-negative\",\"payloadSize\":-1,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"payload-too-large\",\"payloadSize\":131073,\"seed\":1,\"extraWork\":0}",
                "{\"requestId\":\"seed-negative\",\"payloadSize\":1,\"seed\":-1,\"extraWork\":0}",
                "{\"requestId\":\"seed-too-large\",\"payloadSize\":1,\"seed\":2147483648,\"extraWork\":0}",
                "{\"requestId\":\"extra-negative\",\"payloadSize\":1,\"seed\":1,\"extraWork\":-1}",
                "{\"requestId\":\"extra-too-large\",\"payloadSize\":1,\"seed\":1,\"extraWork\":101}"
        );

        for (String body : bodies) {
            assertThrows(IllegalArgumentException.class, () -> WorkValidator.decodeAndValidate(body),
                    "body should be rejected: " + body);
        }
    }

    private static String padToBytes(String value, int targetBytes) {
        int currentBytes = value.getBytes(StandardCharsets.UTF_8).length;
        if (currentBytes > targetBytes) {
            throw new IllegalArgumentException("value is already larger than target");
        }
        return value + " ".repeat(targetBytes - currentBytes);
    }
}
