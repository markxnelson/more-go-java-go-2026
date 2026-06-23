package demo.benchmark;

public record WorkRequest(String requestId, int payloadSize, int seed, int extraWork) {
}
