package load

import (
	"bufio"
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func TestRunWritesMetadataRichJSONL(t *testing.T) {
	var mu sync.Mutex
	var requests int
	var bodies [][]byte
	var contentTypes []string

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body := new(bytes.Buffer)
		_, _ = body.ReadFrom(r.Body)

		mu.Lock()
		requests++
		bodies = append(bodies, append([]byte(nil), body.Bytes()...))
		contentTypes = append(contentTypes, r.Header.Get("Content-Type"))
		mu.Unlock()

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	}))
	defer srv.Close()

	dir := t.TempDir()
	fixturePath := filepath.Join(dir, "fixture.json")
	outPath := filepath.Join(dir, "events.jsonl")
	summaryPath := filepath.Join(dir, "summary.json")

	fixture := []byte(`{"requestId":"test-1","payloadSize":16,"seed":42,"extraWork":0}`)
	if err := os.WriteFile(fixturePath, fixture, 0o644); err != nil {
		t.Fatal(err)
	}

	cfg := Config{
		URL:           srv.URL + "/work",
		Fixture:       fixturePath,
		Output:        outPath,
		SummaryOutput: summaryPath,
		Duration:      120 * time.Millisecond,
		Warmup:        80 * time.Millisecond,
		Concurrency:   1,
		Rate:          20,
		Service:       "orders",
		Variant:       "go",
		Cell:          "dev",
		Repeat:        7,
	}
	if err := Run(cfg); err != nil {
		t.Fatal(err)
	}

	mu.Lock()
	gotRequests := requests
	gotBodies := append([][]byte(nil), bodies...)
	gotContentTypes := append([]string(nil), contentTypes...)
	mu.Unlock()

	if gotRequests == 0 {
		t.Fatal("expected requests")
	}
	for _, b := range gotBodies {
		if !bytes.Equal(b, fixture) {
			t.Fatalf("unexpected request body: %s", string(b))
		}
	}
	for _, ct := range gotContentTypes {
		if ct != "application/json" {
			t.Fatalf("unexpected content type: %q", ct)
		}
	}

	f, err := os.Open(outPath)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	var count int
	var sawWarmup bool
	var sawMeasured bool

	for sc.Scan() {
		count++

		var ev Event
		if err := json.Unmarshal(sc.Bytes(), &ev); err != nil {
			t.Fatal(err)
		}
		if ev.Service != "orders" || ev.Variant != "go" || ev.Cell != "dev" || ev.Repeat != 7 {
			t.Fatalf("missing metadata in event: %+v", ev)
		}
		if ev.Status != http.StatusOK {
			t.Fatalf("unexpected status: %+v", ev)
		}
		if ev.Error != "" {
			t.Fatalf("unexpected event error: %+v", ev)
		}
		if ev.ScheduledUnixNano == 0 || ev.StartedUnixNano == 0 || ev.TimestampUnixNano == 0 {
			t.Fatalf("expected timestamps: %+v", ev)
		}
		if ev.TimestampUnixNano < ev.StartedUnixNano {
			t.Fatalf("expected timestamp >= started: %+v", ev)
		}
		if ev.Warmup {
			sawWarmup = true
		} else {
			sawMeasured = true
		}
	}

	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	if count == 0 {
		t.Fatal("expected events")
	}
	if !sawWarmup {
		t.Fatal("expected at least one warmup event")
	}
	if !sawMeasured {
		t.Fatal("expected at least one measured event")
	}

	summaryBytes, err := os.ReadFile(summaryPath)
	if err != nil {
		t.Fatal(err)
	}

	var summary Summary
	if err := json.Unmarshal(summaryBytes, &summary); err != nil {
		t.Fatal(err)
	}
	if summary.Service != "orders" || summary.Variant != "go" || summary.Cell != "dev" || summary.Repeat != 7 {
		t.Fatalf("unexpected summary metadata: %+v", summary)
	}
	if summary.TotalEvents == 0 || summary.WarmupEvents == 0 || summary.MeasuredEvents == 0 {
		t.Fatalf("expected populated summary counts: %+v", summary)
	}
	if summary.Success2xx != summary.TotalEvents {
		t.Fatalf("expected all events to be 2xx: %+v", summary)
	}
	if summary.Errors != 0 {
		t.Fatalf("expected no event errors: %+v", summary)
	}
}

func TestRunClosedLoopRecordsHTTPFailuresAsEvents(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "nope", http.StatusBadRequest)
	}))
	defer srv.Close()

	dir := t.TempDir()
	fixturePath := filepath.Join(dir, "fixture.json")
	outPath := filepath.Join(dir, "events.jsonl")
	summaryPath := filepath.Join(dir, "summary.json")

	if err := os.WriteFile(fixturePath, []byte(`{"requestId":"test-2","payloadSize":0,"seed":1,"extraWork":0}`), 0o644); err != nil {
		t.Fatal(err)
	}

	cfg := Config{
		URL:           srv.URL + "/work",
		Fixture:       fixturePath,
		Output:        outPath,
		SummaryOutput: summaryPath,
		Duration:      50 * time.Millisecond,
		Concurrency:   1,
		Service:       "orders",
		Variant:       "java",
		Cell:          "dev",
		Repeat:        1,
	}
	if err := Run(cfg); err != nil {
		t.Fatal(err)
	}

	summaryBytes, err := os.ReadFile(summaryPath)
	if err != nil {
		t.Fatal(err)
	}

	var summary Summary
	if err := json.Unmarshal(summaryBytes, &summary); err != nil {
		t.Fatal(err)
	}
	if summary.TotalEvents == 0 {
		t.Fatalf("expected events: %+v", summary)
	}
	if summary.Success2xx != 0 {
		t.Fatalf("expected no 2xx responses: %+v", summary)
	}
	if summary.Errors != 0 {
		t.Fatalf("HTTP non-2xx status should not be recorded as transport error: %+v", summary)
	}
}
