package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	defaultPort        = "18083"
	maxDecodedBody    = 4096
	maxRequestIDBytes = 128
	maxPayloadSize    = 4096
	maxExtraWork      = 10000000
)

type workRequest struct {
	RequestID   string
	PayloadSize int64
	Seed        int64
	ExtraWork   int64
}

func main() {
	port := strings.TrimSpace(os.Getenv("FAST_ECHO_PORT"))
	if port == "" {
		port = defaultPort
	}

	addr := port
	if !strings.HasPrefix(addr, ":") {
		addr = ":" + addr
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", health)
	mux.HandleFunc("/work", work)

	server := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	log.Printf("fast-echo listening on %s", addr)
	log.Fatal(server.ListenAndServe())
}

func health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)

	if r.Method == http.MethodGet {
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	}
}

func work(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	if !isJSONContentType(r.Header.Get("Content-Type")) {
		http.Error(w, "content type must be application/json", http.StatusUnsupportedMediaType)
		return
	}

	body, err := readLimitedBody(r.Body)
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, errBodyTooLarge) {
			status = http.StatusRequestEntityTooLarge
		}
		http.Error(w, err.Error(), status)
		return
	}

	req, err := decodeWorkRequest(body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	runExtraWork(req)

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`{"status":"ok"}`))
}

var errBodyTooLarge = errors.New("decoded request body too large")

func readLimitedBody(r io.Reader) ([]byte, error) {
	body, err := io.ReadAll(io.LimitReader(r, maxDecodedBody+1))
	if err != nil {
		return nil, fmt.Errorf("failed to read request body: %w", err)
	}
	if len(body) > maxDecodedBody {
		return nil, errBodyTooLarge
	}
	return body, nil
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

func decodeWorkRequest(body []byte) (workRequest, error) {
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.UseNumber()

	tok, err := dec.Token()
	if err != nil {
		return workRequest{}, fmt.Errorf("invalid JSON: %w", err)
	}
	delim, ok := tok.(json.Delim)
	if !ok || delim != '{' {
		return workRequest{}, errors.New("request body must be a JSON object")
	}

	var req workRequest
	seen := map[string]bool{}

	for dec.More() {
		keyTok, err := dec.Token()
		if err != nil {
			return workRequest{}, fmt.Errorf("invalid JSON object key: %w", err)
		}

		key, ok := keyTok.(string)
		if !ok {
			return workRequest{}, errors.New("invalid JSON object key")
		}
		if seen[key] {
			return workRequest{}, fmt.Errorf("duplicate field %q", key)
		}
		seen[key] = true

		switch key {
		case "requestId":
			var value string
			if err := dec.Decode(&value); err != nil {
				return workRequest{}, fmt.Errorf("field requestId must be a string: %w", err)
			}
			if value == "" {
				return workRequest{}, errors.New("field requestId must not be empty")
			}
			if len(value) > maxRequestIDBytes {
				return workRequest{}, fmt.Errorf("field requestId must be at most %d bytes", maxRequestIDBytes)
			}
			req.RequestID = value

		case "payloadSize":
			value, err := decodeInt64Field(dec, "payloadSize")
			if err != nil {
				return workRequest{}, err
			}
			if value < 0 || value > maxPayloadSize {
				return workRequest{}, fmt.Errorf("field payloadSize must be between 0 and %d", maxPayloadSize)
			}
			req.PayloadSize = value

		case "seed":
			value, err := decodeInt64Field(dec, "seed")
			if err != nil {
				return workRequest{}, err
			}
			req.Seed = value

		case "extraWork":
			value, err := decodeInt64Field(dec, "extraWork")
			if err != nil {
				return workRequest{}, err
			}
			if value < 0 || value > maxExtraWork {
				return workRequest{}, fmt.Errorf("field extraWork must be between 0 and %d", maxExtraWork)
			}
			req.ExtraWork = value

		default:
			return workRequest{}, fmt.Errorf("unknown field %q", key)
		}
	}

	tok, err = dec.Token()
	if err != nil {
		return workRequest{}, fmt.Errorf("invalid JSON object: %w", err)
	}
	delim, ok = tok.(json.Delim)
	if !ok || delim != '}' {
		return workRequest{}, errors.New("invalid JSON object")
	}

	if dec.More() {
		return workRequest{}, errors.New("invalid trailing JSON")
	}

	var trailing any
	if err := dec.Decode(&trailing); err != io.EOF {
		if err == nil {
			return workRequest{}, errors.New("invalid trailing JSON")
		}
		return workRequest{}, fmt.Errorf("invalid trailing JSON: %w", err)
	}

	for _, required := range []string{"requestId", "payloadSize", "seed", "extraWork"} {
		if !seen[required] {
			return workRequest{}, fmt.Errorf("missing field %q", required)
		}
	}

	return req, nil
}

func decodeInt64Field(dec *json.Decoder, name string) (int64, error) {
	var value json.Number
	if err := dec.Decode(&value); err != nil {
		return 0, fmt.Errorf("field %s must be an integer number: %w", name, err)
	}

	text := value.String()
	if text == "" {
		return 0, fmt.Errorf("field %s must be an integer number", name)
	}
	if strings.ContainsAny(text, ".eE") {
		return 0, fmt.Errorf("field %s must be an integer number", name)
	}

	parsed, err := strconv.ParseInt(text, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("field %s must be an integer number: %w", name, err)
	}

	return parsed, nil
}

func runExtraWork(req workRequest) {
	var acc uint64 = uint64(req.Seed) ^ uint64(req.PayloadSize)

	for i := int64(0); i < req.ExtraWork; i++ {
		acc ^= uint64(i) + 0x9e3779b97f4a7c15
		acc *= 1099511628211
		acc ^= acc >> 32
	}

	if acc == 0xffffffffffffffff {
		log.Print("unreachable accumulator value")
	}
}
