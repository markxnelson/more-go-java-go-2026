package demo.benchmark;

import com.fasterxml.jackson.databind.JsonNode;

import java.nio.charset.StandardCharsets;
import java.util.Iterator;
import java.util.Set;

public final class WorkValidator {
    public static final int BODY_LIMIT_BYTES = 4096;

    private static final Set<String> ALLOWED_FIELDS = Set.of(
            "requestId",
            "payloadSize",
            "seed",
            "extraWork");

    private WorkValidator() {
    }

    public static WorkRequest decodeAndValidate(String body) {
        if (body.getBytes(StandardCharsets.UTF_8).length > BODY_LIMIT_BYTES) {
            throw new BodyTooLargeException("body too large");
        }

        JsonNode node = JsonSupport.readTreeStrict(body);
        if (!node.isObject()) {
            throw new IllegalArgumentException("body must be a json object");
        }

        Iterator<String> fieldNames = node.fieldNames();
        while (fieldNames.hasNext()) {
            String fieldName = fieldNames.next();
            if (!ALLOWED_FIELDS.contains(fieldName)) {
                throw new IllegalArgumentException("unknown field: " + fieldName);
            }
        }

        String requestId = requiredString(node, "requestId");
        int payloadSize = requiredInt(node, "payloadSize", 0, 131072);
        int seed = requiredInt(node, "seed", 0, 2147483647);
        int extraWork = requiredInt(node, "extraWork", 0, 100);

        if (requestId.isEmpty() || requestId.length() > 128) {
            throw new IllegalArgumentException("requestId length out of range");
        }

        return new WorkRequest(requestId, payloadSize, seed, extraWork);
    }

    private static String requiredString(JsonNode node, String name) {
        JsonNode value = node.get(name);
        if (value == null) {
            throw new IllegalArgumentException("missing field: " + name);
        }
        if (!value.isTextual()) {
            throw new IllegalArgumentException(name + " must be a string");
        }
        return value.asText();
    }

    private static int requiredInt(JsonNode node, String name, int min, int max) {
        JsonNode value = node.get(name);
        if (value == null) {
            throw new IllegalArgumentException("missing field: " + name);
        }
        if (!value.isIntegralNumber()) {
            throw new IllegalArgumentException(name + " must be a json integer number");
        }
        if (!value.canConvertToInt()) {
            throw new IllegalArgumentException(name + " out of range");
        }

        int number = value.intValue();
        if (number < min || number > max) {
            throw new IllegalArgumentException(name + " out of range");
        }

        return number;
    }
}
