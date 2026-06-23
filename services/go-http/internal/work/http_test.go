package work

import (
	"encoding/json"
	"math"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHealthExact(t *testing.T) {
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/health", nil)

	NewHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%q", rr.Code, rr.Body.String())
	}
	if rr.Body.String() != `{"status":"ok"}` {
		t.Fatalf("body=%q", rr.Body.String())
	}
}

func TestHeadHealthNoBody(t *testing.T) {
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodHead, "/health", nil)

	NewHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%q", rr.Code, rr.Body.String())
	}
	if rr.Body.Len() != 0 {
		t.Fatalf("expected no body, got %q", rr.Body.String())
	}
}

func TestHealthRejectsUnsupportedMethod(t *testing.T) {
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/health", nil)

	NewHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status=%d body=%q", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("Allow") != "GET, HEAD" {
		t.Fatalf("Allow header=%q", rr.Header().Get("Allow"))
	}
}

func TestWorkValid(t *testing.T) {
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/work", strings.NewReader(`{"requestId":"a","payloadSize":1,"seed":1,"extraWork":0}`))
	req.Header.Set("Content-Type", "application/json")

	NewHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}

	var resp Response
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("response is not valid json: %v", err)
	}
	if !resp.OK {
		t.Fatalf("expected ok response: %#v", resp)
	}
	if resp.RequestID != "a" || resp.PayloadSize != 1 || resp.ExtraWork != 0 || resp.Checksum == "" {
		t.Fatalf("unexpected response: %#v", resp)
	}
}

func TestWorkAcceptsJSONContentTypeWithCharset(t *testing.T) {
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/work", strings.NewReader(`{"requestId":"a","payloadSize":1,"seed":1,"extraWork":0}`))
	req.Header.Set("Content-Type", "application/json; charset=utf-8")

	NewHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestWorkRejectsInvalidContentType(t *testing.T) {
	cases := []string{
		"",
		"text/plain",
		"application/jsonx",
		"not a media type",
	}

	for _, contentType := range cases {
		t.Run(contentType, func(t *testing.T) {
			rr := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, "/work", strings.NewReader(`{"requestId":"a","payloadSize":1,"seed":1,"extraWork":0}`))
			if contentType != "" {
				req.Header.Set("Content-Type", contentType)
			}

			NewHandler().ServeHTTP(rr, req)

			if rr.Code != http.StatusUnsupportedMediaType {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
		})
	}
}

func TestWorkRejectsUnsupportedMethod(t *testing.T) {
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/work", nil)

	NewHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status=%d body=%q", rr.Code, rr.Body.String())
	}
	if rr.Header().Get("Allow") != "POST" {
		t.Fatalf("Allow header=%q", rr.Header().Get("Allow"))
	}
}

func TestWorkRejectsOversizedDecodedBody(t *testing.T) {
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/work", strings.NewReader(strings.Repeat("A", BodyLimitBytes+1)))
	req.Header.Set("Content-Type", "application/json")

	NewHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
}

func TestNotFound(t *testing.T) {
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/missing", nil)

	NewHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Fatalf("status=%d body=%q", rr.Code, rr.Body.String())
	}
}

func TestDebugVarsReachable(t *testing.T) {
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/debug/vars", nil)

	NewHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%q", rr.Code, rr.Body.String())
	}

	var vars map[string]json.RawMessage
	if err := json.Unmarshal(rr.Body.Bytes(), &vars); err != nil {
		t.Fatalf("/debug/vars did not return JSON: %v; body=%q", err, rr.Body.String())
	}
	if len(vars) == 0 {
		t.Fatalf("expected at least one expvar entry")
	}
}

func TestDebugRuntimeMetricsReachable(t *testing.T) {
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/debug/runtime-metrics", nil)

	NewHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%q", rr.Code, rr.Body.String())
	}
	if rr.Body.Len() == 0 {
		t.Fatalf("/debug/runtime-metrics returned an empty body")
	}

	var resp struct {
		Timestamp string `json:"timestamp"`
		Metrics   []struct {
			Name  string          `json:"name"`
			Kind  string          `json:"kind"`
			Value json.RawMessage `json:"value"`
		} `json:"metrics"`
	}
	if err := json.Unmarshal(rr.Body.Bytes(), &resp); err != nil {
		t.Fatalf("/debug/runtime-metrics did not return JSON: %v; body=%q", err, rr.Body.String())
	}
	if _, err := time.Parse(time.RFC3339Nano, resp.Timestamp); err != nil {
		t.Fatalf("timestamp is not RFC3339Nano: %q: %v", resp.Timestamp, err)
	}
	if len(resp.Metrics) == 0 {
		t.Fatalf("expected runtime metric samples")
	}
	if resp.Metrics[0].Name == "" || resp.Metrics[0].Kind == "" {
		t.Fatalf("expected metric name and kind, got %#v", resp.Metrics[0])
	}
}

func TestDebugPprofIndexReachable(t *testing.T) {
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/debug/pprof/", nil)

	NewHandler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%q", rr.Code, rr.Body.String())
	}
	if !strings.Contains(rr.Body.String(), "Types of profiles available") {
		t.Fatalf("expected pprof index body, got %q", rr.Body.String())
	}
}

func TestJSONSafeFloat64EncodesNonFiniteValues(t *testing.T) {
	values := []any{
		jsonSafeFloat64(math.Inf(1)),
		jsonSafeFloat64(math.Inf(-1)),
		jsonSafeFloat64(math.NaN()),
		jsonSafeFloat64(1.25),
	}

	body, err := json.Marshal(values)
	if err != nil {
		t.Fatalf("expected JSON-safe values, got error: %v", err)
	}

	got := string(body)
	if !strings.Contains(got, `"+Inf"`) {
		t.Fatalf("expected +Inf string in %s", got)
	}
	if !strings.Contains(got, `"-Inf"`) {
		t.Fatalf("expected -Inf string in %s", got)
	}
	if !strings.Contains(got, `"NaN"`) {
		t.Fatalf("expected NaN string in %s", got)
	}
	if !strings.Contains(got, `1.25`) {
		t.Fatalf("expected finite float to remain numeric in %s", got)
	}
}
