package load

import (
	"math"
	"strings"
	"testing"
	"time"
)

func TestConfigValidateAcceptsMinimalConfig(t *testing.T) {
	cfg := validConfig()

	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestConfigValidateAcceptsExtendedConfig(t *testing.T) {
	cfg := validConfig()
	cfg.Concurrency = 8
	cfg.Warmup = 250 * time.Millisecond
	cfg.Rate = 120.5
	cfg.Service = "go"
	cfg.Variant = "helidon-comparison"
	cfg.Cell = "small-payload"
	cfg.Repeat = 3
	cfg.RunID = "run-001"
	cfg.SummaryOutput = "artifacts/raw/summary.json"
	cfg.ManifestOutput = "manifests/run-001.json"
	cfg.ProfileArtifacts = []ProfileArtifact{
		{Kind: ArtifactGoCPUProfile, Path: "artifacts/profiles/go/cpu.pprof"},
		{Kind: ArtifactGoHeapProfile, Path: "artifacts/profiles/go/heap.pprof"},
		{Kind: ArtifactGoRuntimeMetrics, Path: "artifacts/profiles/go/runtime-metrics.json"},
		{Kind: ArtifactJavaGCLog, Path: "artifacts/profiles/java/gc.log"},
		{Kind: ArtifactJavaJFR, Path: "artifacts/profiles/java/recording.jfr"},
	}

	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestConfigValidateRejectsInvalidConfig(t *testing.T) {
	tests := []struct {
		name string
		edit func(*Config)
	}{
		{
			name: "missing url",
			edit: func(c *Config) { c.URL = "" },
		},
		{
			name: "invalid url",
			edit: func(c *Config) { c.URL = "://bad" },
		},
		{
			name: "unsupported scheme",
			edit: func(c *Config) { c.URL = "ftp://127.0.0.1/work" },
		},
		{
			name: "missing host",
			edit: func(c *Config) { c.URL = "http:///work" },
		},
		{
			name: "wrong path",
			edit: func(c *Config) { c.URL = "http://127.0.0.1/health" },
		},
		{
			name: "missing fixture",
			edit: func(c *Config) { c.Fixture = "" },
		},
		{
			name: "missing output",
			edit: func(c *Config) { c.Output = "" },
		},
		{
			name: "zero duration",
			edit: func(c *Config) { c.Duration = 0 },
		},
		{
			name: "negative warmup",
			edit: func(c *Config) { c.Warmup = -time.Millisecond },
		},
		{
			name: "zero concurrency",
			edit: func(c *Config) { c.Concurrency = 0 },
		},
		{
			name: "too much concurrency",
			edit: func(c *Config) { c.Concurrency = MaxConcurrency + 1 },
		},
		{
			name: "negative rate",
			edit: func(c *Config) { c.Rate = -1 },
		},
		{
			name: "nan rate",
			edit: func(c *Config) { c.Rate = math.NaN() },
		},
		{
			name: "inf rate",
			edit: func(c *Config) { c.Rate = math.Inf(1) },
		},
		{
			name: "negative repeat",
			edit: func(c *Config) { c.Repeat = -1 },
		},
		{
			name: "control character in label",
			edit: func(c *Config) { c.Service = "go\nbad" },
		},
		{
			name: "label too long",
			edit: func(c *Config) { c.Cell = strings.Repeat("x", MaxLabelLength+1) },
		},
		{
			name: "profile artifact without manifest",
			edit: func(c *Config) {
				c.ProfileArtifacts = []ProfileArtifact{{Kind: ArtifactGoCPUProfile, Path: "cpu.pprof"}}
			},
		},
		{
			name: "invalid profile artifact kind",
			edit: func(c *Config) {
				c.ManifestOutput = "manifest.json"
				c.ProfileArtifacts = []ProfileArtifact{{Kind: ArtifactKind("unknown"), Path: "profile.dat"}}
			},
		},
		{
			name: "invalid profile artifact path",
			edit: func(c *Config) {
				c.ManifestOutput = "manifest.json"
				c.ProfileArtifacts = []ProfileArtifact{{Kind: ArtifactGoCPUProfile, Path: ""}}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := validConfig()
			tt.edit(&cfg)
			if err := cfg.Validate(); err == nil {
				t.Fatal("expected validation error")
			}
		})
	}
}

func validConfig() Config {
	return Config{
		URL:         "http://127.0.0.1:18081/work",
		Fixture:     "fixtures/valid/work-small.json",
		Output:      "artifacts/raw/events.jsonl",
		Duration:    time.Second,
		Concurrency: 1,
	}
}
