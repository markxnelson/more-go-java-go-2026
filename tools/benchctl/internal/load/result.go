package load

import (
	"errors"
	"fmt"
	"strings"
	"unicode"
)

type ArtifactKind string

const (
	ArtifactJavaGCLog       ArtifactKind = "java-gc-log"
	ArtifactJavaJFR         ArtifactKind = "java-jfr"
	ArtifactGoCPUProfile    ArtifactKind = "go-cpu-profile"
	ArtifactGoHeapProfile   ArtifactKind = "go-heap-profile"
	ArtifactGoRuntimeMetrics ArtifactKind = "go-runtime-metrics"
)

type Event struct {
	RunID             string `json:"runId,omitempty"`
	Service           string `json:"service,omitempty"`
	Variant           string `json:"variant,omitempty"`
	Cell              string `json:"cell,omitempty"`
	Repeat            int    `json:"repeat"`
	Warmup            bool   `json:"warmup"`
	Worker            int    `json:"worker"`
	Status            int    `json:"status"`
	LatencyMicros     int64  `json:"latencyMicros"`
	ScheduledUnixNano int64  `json:"scheduledUnixNano"`
	StartedUnixNano   int64  `json:"startedUnixNano"`
	TimestampUnixNano int64  `json:"timestampUnixNano"`
	Error             string `json:"error,omitempty"`
}

type Summary struct {
	RunID            string            `json:"runId,omitempty"`
	Service          string            `json:"service,omitempty"`
	Variant          string            `json:"variant,omitempty"`
	Cell             string            `json:"cell,omitempty"`
	Repeat           int               `json:"repeat"`
	WarmupDuration   int64             `json:"warmupDurationNanos"`
	Duration         int64             `json:"durationNanos"`
	Concurrency      int               `json:"concurrency"`
	Rate             float64           `json:"rate"`
	TotalEvents      int64             `json:"totalEvents"`
	MeasuredEvents   int64             `json:"measuredEvents"`
	WarmupEvents     int64             `json:"warmupEvents"`
	Success2xx       int64             `json:"success2xx"`
	Errors           int64             `json:"errors"`
	Output           string            `json:"output"`
	SummaryOutput    string            `json:"summaryOutput,omitempty"`
	ManifestOutput   string            `json:"manifestOutput,omitempty"`
	ProfileArtifacts []ProfileArtifact `json:"profileArtifacts,omitempty"`
}

type ProfileArtifact struct {
	Kind        ArtifactKind `json:"kind"`
	Path        string       `json:"path"`
	Description string       `json:"description,omitempty"`
}

func (a ProfileArtifact) Validate() error {
	if !validArtifactKind(a.Kind) {
		return fmt.Errorf("unsupported kind %q", a.Kind)
	}
	if strings.TrimSpace(a.Path) == "" {
		return errors.New("path is required")
	}
	for _, r := range a.Path {
		if unicode.IsControl(r) {
			return errors.New("path must not contain control characters")
		}
	}
	return nil
}

type RunManifest struct {
	SchemaVersion    int               `json:"schemaVersion"`
	RunID            string            `json:"runId,omitempty"`
	CreatedUnixNano int64             `json:"createdUnixNano"`
	Service          string            `json:"service,omitempty"`
	Variant          string            `json:"variant,omitempty"`
	Cell             string            `json:"cell,omitempty"`
	Repeat           int               `json:"repeat"`
	TargetURL        string            `json:"targetUrl"`
	Fixture          string            `json:"fixture"`
	Output           string            `json:"output"`
	SummaryOutput    string            `json:"summaryOutput,omitempty"`
	ProfileArtifacts []ProfileArtifact `json:"profileArtifacts,omitempty"`
	Summary           *Summary          `json:"summary,omitempty"`
	Notes            []string          `json:"notes,omitempty"`
}

func validArtifactKind(kind ArtifactKind) bool {
	switch kind {
	case ArtifactJavaGCLog,
		ArtifactJavaJFR,
		ArtifactGoCPUProfile,
		ArtifactGoHeapProfile,
		ArtifactGoRuntimeMetrics:
		return true
	default:
		return false
	}
}
