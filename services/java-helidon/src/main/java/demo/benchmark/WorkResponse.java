package demo.benchmark;

import com.fasterxml.jackson.annotation.JsonProperty;

public record WorkResponse(
        @JsonProperty("requestId") String requestId,
        @JsonProperty("payloadSize") int payloadSize,
        @JsonProperty("extraWork") int extraWork,
        @JsonProperty("checksum") String checksum,
        @JsonProperty("ok") boolean ok) {
}
