package work

import (
	"encoding/json"
	"errors"
	"expvar"
	"math"
	"mime"
	"net/http"
	"net/http/pprof"
	"runtime/metrics"
	"strings"
	"time"
)

func NewHandler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/work", workHandler)

	mux.HandleFunc("/debug/pprof/", pprof.Index)
	mux.HandleFunc("/debug/pprof/cmdline", pprof.Cmdline)
	mux.HandleFunc("/debug/pprof/profile", pprof.Profile)
	mux.HandleFunc("/debug/pprof/symbol", pprof.Symbol)
	mux.HandleFunc("/debug/pprof/trace", pprof.Trace)
	mux.Handle("/debug/vars", expvar.Handler())
	mux.HandleFunc("/debug/runtime-metrics", runtimeMetricsHandler)

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/health" && r.URL.Path != "/work" && !isDebugRoute(r.URL.Path) {
			writeError(w, http.StatusNotFound, "not_found", "route not found")
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)

	if r.Method == http.MethodHead {
		return
	}

	_, _ = w.Write([]byte(`{"status":"ok"}`))
}

func workHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}

	if !isJSONContentType(r.Header.Get("Content-Type")) {
		writeError(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "content-type must be application/json")
		return
	}

	req, err := DecodeAndValidate(r.Body)
	if err != nil {
		if errors.Is(err, ErrBodyTooLarge) {
			writeError(w, http.StatusRequestEntityTooLarge, "body_too_large", "decoded body exceeds limit")
			return
		}
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}

	resp := Response{
		RequestID:   req.RequestID,
		PayloadSize: req.PayloadSize,
		ExtraWork:   req.ExtraWork,
		Checksum:    ComputeChecksum(req),
		OK:          true,
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(resp)
}

func isJSONContentType(value string) bool {
	if strings.TrimSpace(value) == "" {
		return false
	}

	mediaType, _, err := mime.ParseMediaType(value)
	if err != nil {
		return false
	}

	return strings.EqualFold(mediaType, "application/json")
}

func isDebugRoute(path string) bool {
	return path == "/debug/vars" ||
		path == "/debug/runtime-metrics" ||
		strings.HasPrefix(path, "/debug/pprof/")
}

type runtimeMetricsResponse struct {
	Timestamp string                `json:"timestamp"`
	Metrics   []runtimeMetricSample `json:"metrics"`
}

type runtimeMetricSample struct {
	Name  string `json:"name"`
	Kind  string `json:"kind"`
	Value any    `json:"value"`
}

type runtimeMetricHistogram struct {
	Counts  []uint64 `json:"counts"`
	Buckets []any    `json:"buckets"`
}

func runtimeMetricsHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}

	descriptions := metrics.All()
	samples := make([]metrics.Sample, len(descriptions))
	for i, description := range descriptions {
		samples[i].Name = description.Name
	}

	metrics.Read(samples)

	resp := runtimeMetricsResponse{
		Timestamp: time.Now().UTC().Format(time.RFC3339Nano),
		Metrics:   make([]runtimeMetricSample, 0, len(samples)),
	}

	for _, sample := range samples {
		kind, value := runtimeMetricValue(sample.Value)
		resp.Metrics = append(resp.Metrics, runtimeMetricSample{
			Name:  sample.Name,
			Kind:  kind,
			Value: value,
		})
	}

	body, err := json.Marshal(resp)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "runtime_metrics_encode_failed", "failed to encode runtime metrics")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)

	if r.Method == http.MethodHead {
		return
	}

	_, _ = w.Write(body)
}

func runtimeMetricValue(value metrics.Value) (string, any) {
	switch value.Kind() {
	case metrics.KindUint64:
		return "uint64", value.Uint64()
	case metrics.KindFloat64:
		return "float64", jsonSafeFloat64(value.Float64())
	case metrics.KindFloat64Histogram:
		histogram := value.Float64Histogram()
		return "float64_histogram", runtimeMetricHistogram{
			Counts:  append([]uint64(nil), histogram.Counts...),
			Buckets: jsonSafeFloat64Slice(histogram.Buckets),
		}
	default:
		return "bad", nil
	}
}

func jsonSafeFloat64Slice(values []float64) []any {
	out := make([]any, len(values))
	for i, value := range values {
		out[i] = jsonSafeFloat64(value)
	}
	return out
}

func jsonSafeFloat64(value float64) any {
	switch {
	case math.IsInf(value, 1):
		return "+Inf"
	case math.IsInf(value, -1):
		return "-Inf"
	case math.IsNaN(value):
		return "NaN"
	default:
		return value
	}
}
