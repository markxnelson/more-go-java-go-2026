package demo.benchmark;

import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.StreamReadFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.IOException;

public final class JsonSupport {
    static final JsonFactory FACTORY = JsonFactory.builder()
            .enable(StreamReadFeature.STRICT_DUPLICATE_DETECTION)
            .build();

    static final ObjectMapper MAPPER = new ObjectMapper(FACTORY);

    private JsonSupport() {
    }

    public static JsonNode readTreeStrict(String body) {
        try (JsonParser parser = FACTORY.createParser(body)) {
            JsonNode node = MAPPER.readTree(parser);
            if (node == null) {
                throw new IllegalArgumentException("empty json body");
            }
            if (parser.nextToken() != null) {
                throw new IllegalArgumentException("multiple json documents");
            }
            return node;
        } catch (IOException e) {
            throw new IllegalArgumentException("invalid json: " + e.getMessage(), e);
        }
    }

    public static String write(Object value) {
        try {
            return MAPPER.writeValueAsString(value);
        } catch (IOException e) {
            throw new IllegalStateException("json write failed", e);
        }
    }
}
