package demo.benchmark;

public record ErrorResponse(boolean ok, ErrorInfo error) {
    public record ErrorInfo(String code, String message) {
    }
}
