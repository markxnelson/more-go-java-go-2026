package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	"example.com/more-go-java-go/tools/benchctl/internal/load"
)

func main() {
	var cfg load.Config
	var artifacts []load.ProfileArtifact

	flag.StringVar(&cfg.URL, "url", "", "target POST /work URL")
	flag.StringVar(&cfg.Fixture, "fixture", "", "request fixture path")
	flag.StringVar(&cfg.Output, "out", "", "output JSONL path")
	flag.DurationVar(&cfg.Duration, "duration", 2*time.Second, "measured run duration")
	flag.IntVar(&cfg.Concurrency, "concurrency", 1, "worker count")

	flag.DurationVar(&cfg.Warmup, "warmup", 0, "warmup duration before measured run")
	flag.Float64Var(&cfg.Rate, "rate", 0, "target requests per second across all workers; 0 means closed-loop")
	flag.StringVar(&cfg.Service, "service", "", "service label to include in output events")
	flag.StringVar(&cfg.Variant, "variant", "", "variant label to include in output events")
	flag.StringVar(&cfg.Cell, "cell", "", "cell label to include in output events")
	flag.IntVar(&cfg.Repeat, "repeat", 0, "repeat number label to include in output events")
	flag.StringVar(&cfg.RunID, "run-id", "", "optional stable run identifier for summaries and manifests")
	flag.StringVar(&cfg.SummaryOutput, "summary-out", "", "optional summary JSON output path")
	flag.StringVar(&cfg.ManifestOutput, "manifest-out", "", "optional run manifest JSON output path")

	flag.Var(profileArtifactFlag{dst: &artifacts}, "profile-artifact", "profile artifact as kind:path; repeatable; kinds: java-gc-log, java-jfr, go-cpu-profile, go-heap-profile, go-runtime-metrics")
	flag.Var(artifactPathFlag{dst: &artifacts, kind: load.ArtifactJavaGCLog}, "java-gc-log", "Java GC log artifact path; repeatable")
	flag.Var(artifactPathFlag{dst: &artifacts, kind: load.ArtifactJavaJFR}, "java-jfr", "Java JFR recording artifact path; repeatable")
	flag.Var(artifactPathFlag{dst: &artifacts, kind: load.ArtifactGoCPUProfile}, "go-cpu-profile", "Go CPU profile artifact path; repeatable")
	flag.Var(artifactPathFlag{dst: &artifacts, kind: load.ArtifactGoHeapProfile}, "go-heap-profile", "Go heap profile artifact path; repeatable")
	flag.Var(artifactPathFlag{dst: &artifacts, kind: load.ArtifactGoRuntimeMetrics}, "go-runtime-metrics", "Go runtime metrics snapshot artifact path; repeatable")

	flag.Parse()

	cfg.ProfileArtifacts = artifacts

	if err := cfg.Validate(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if err := load.Run(cfg); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

type profileArtifactFlag struct {
	dst *[]load.ProfileArtifact
}

func (f profileArtifactFlag) String() string {
	if f.dst == nil || len(*f.dst) == 0 {
		return ""
	}
	parts := make([]string, 0, len(*f.dst))
	for _, artifact := range *f.dst {
		parts = append(parts, string(artifact.Kind)+":"+artifact.Path)
	}
	return strings.Join(parts, ",")
}

func (f profileArtifactFlag) Set(value string) error {
	kind, path, ok := strings.Cut(value, ":")
	if !ok {
		return fmt.Errorf("profile artifact must use kind:path format")
	}
	artifact := load.ProfileArtifact{
		Kind: load.ArtifactKind(kind),
		Path: path,
	}
	if err := artifact.Validate(); err != nil {
		return err
	}
	*f.dst = append(*f.dst, artifact)
	return nil
}

type artifactPathFlag struct {
	dst  *[]load.ProfileArtifact
	kind load.ArtifactKind
}

func (f artifactPathFlag) String() string {
	if f.dst == nil || len(*f.dst) == 0 {
		return ""
	}
	paths := make([]string, 0, len(*f.dst))
	for _, artifact := range *f.dst {
		if artifact.Kind == f.kind {
			paths = append(paths, artifact.Path)
		}
	}
	return strings.Join(paths, ",")
}

func (f artifactPathFlag) Set(value string) error {
	artifact := load.ProfileArtifact{
		Kind: f.kind,
		Path: value,
	}
	if err := artifact.Validate(); err != nil {
		return err
	}
	*f.dst = append(*f.dst, artifact)
	return nil
}
