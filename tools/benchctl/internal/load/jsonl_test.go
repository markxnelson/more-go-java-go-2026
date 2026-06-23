package load

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestJSONLWriterAndReader(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	w, err := NewWriter(path)
	if err != nil {
		t.Fatal(err)
	}

	events := []Event{
		{
			RunID:             "run-001",
			Service:           "go",
			Variant:           "v1",
			Cell:              "cell-a",
			Repeat:            2,
			Warmup:            true,
			Worker:            3,
			Status:            200,
			LatencyMicros:     1234,
			ScheduledUnixNano: 100,
			StartedUnixNano:   101,
			TimestampUnixNano: 102,
		},
		{
			RunID:             "run-001",
			Service:           "go",
			Variant:           "v1",
			Cell:              "cell-a",
			Repeat:            2,
			Warmup:            false,
			Worker:            4,
			Status:            500,
			LatencyMicros:     2345,
			ScheduledUnixNano: 200,
			StartedUnixNano:   201,
			TimestampUnixNano: 202,
			Error:             "server returned 500",
		},
	}

	for _, event := range events {
		if err := w.Write(event); err != nil {
			t.Fatal(err)
		}
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}

	got, err := ReadEvents(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(events) {
		t.Fatalf("expected %d events, got %d", len(events), len(got))
	}
	if got[0].Service != "go" || got[0].Variant != "v1" || got[0].Cell != "cell-a" {
		t.Fatal("expected metadata fields")
	}
	if !got[0].Warmup || got[0].Worker != 3 || got[0].Status != 200 {
		t.Fatal("expected first event fields")
	}
	if got[0].ScheduledUnixNano != 100 || got[0].StartedUnixNano != 101 || got[0].TimestampUnixNano != 102 {
		t.Fatal("expected timestamp fields")
	}
	if got[1].Warmup || got[1].Status != 500 || got[1].Error == "" {
		t.Fatal("expected second event error fields")
	}
}

func TestJSONLWriterRejectsWriteAfterClose(t *testing.T) {
	path := filepath.Join(t.TempDir(), "events.jsonl")
	w, err := NewWriter(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	if err := w.Write(Event{}); err == nil {
		t.Fatal("expected write after close to fail")
	}
}

func TestWriteSummary(t *testing.T) {
	path := filepath.Join(t.TempDir(), "summary.json")
	summary := Summary{
		RunID:          "run-001",
		Service:        "java",
		Variant:        "helidon",
		Cell:           "small",
		Repeat:         1,
		Duration:       int64(10_000_000_000),
		Concurrency:    4,
		Rate:           100,
		TotalEvents:    1000,
		MeasuredEvents: 900,
		WarmupEvents:   100,
		Success2xx:     990,
		Errors:         10,
		Output:         "events.jsonl",
		SummaryOutput:  path,
	}

	if err := WriteSummary(path, summary); err != nil {
		t.Fatal(err)
	}

	var got Summary
	readJSON(t, path, &got)
	if got.RunID != "run-001" || got.Service != "java" || got.TotalEvents != 1000 {
		t.Fatal("summary did not round trip")
	}
}

func TestWriteManifest(t *testing.T) {
	path := filepath.Join(t.TempDir(), "manifest.json")
	manifest := RunManifest{
		SchemaVersion:   1,
		RunID:           "run-001",
		CreatedUnixNano: 123,
		TargetURL:       "http://127.0.0.1:18081/work",
		Fixture:         "fixtures/valid/work-small.json",
		Output:          "artifacts/raw/events.jsonl",
		SummaryOutput:   "artifacts/raw/summary.json",
		ProfileArtifacts: []ProfileArtifact{
			{Kind: ArtifactGoCPUProfile, Path: "artifacts/profiles/go/cpu.pprof"},
			{Kind: ArtifactGoRuntimeMetrics, Path: "artifacts/profiles/go/runtime-metrics.json"},
		},
	}

	if err := WriteManifest(path, manifest); err != nil {
		t.Fatal(err)
	}

	var got RunManifest
	readJSON(t, path, &got)
	if got.SchemaVersion != 1 || got.RunID != "run-001" {
		t.Fatal("manifest did not round trip")
	}
	if len(got.ProfileArtifacts) != 2 {
		t.Fatalf("expected 2 profile artifacts, got %d", len(got.ProfileArtifacts))
	}
}

func readJSON(t *testing.T, path string, dst any) {
	t.Helper()

	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(b, dst); err != nil {
		t.Fatal(err)
	}
}
