# benchctl

`benchctl` is the small Go load generator used by this benchmark package.

It sends a fixed JSON fixture to a target service `POST /work` endpoint and writes raw request events as JSON Lines (`.jsonl`). It is intentionally simple: it records what happened during the run, but it does not interpret benchmark results or fabricate measurements.

## Build

From this directory:

```bash
go test ./...
go build ./cmd/benchctl
```

Or from the package root:

```bash
go test ./tools/benchctl/...
go build -o artifacts/bin/benchctl ./tools/benchctl/cmd/benchctl
```

## Basic use

```bash
./benchctl \
  -url http://127.0.0.1:18081/work \
  -fixture ../../fixtures/valid/work-small.json \
  -out ../../artifacts/raw/go-small.jsonl \
  -duration 10s \
  -concurrency 4
```

`benchctl` supports two load modes:

- **Closed loop** when `-rate` is `0`: each worker sends the next request as soon as the previous request finishes.
- **Rate limited** when `-rate` is greater than `0`: requests are scheduled across all workers at approximately the requested aggregate requests per second.

## Common flags

- `-url`: target `POST /work` URL. The path must be `/work`.
- `-fixture`: JSON request body fixture to send.
- `-out`: raw JSONL event output path.
- `-duration`: measured run duration.
- `-concurrency`: worker count.
- `-warmup`: optional warmup duration before the measured phase.
- `-rate`: aggregate requests per second. Use `0` for closed-loop mode.
- `-service`: service label, for example `go`, `java`, or `fast-echo`.
- `-variant`: variant label.
- `-cell`: benchmark matrix cell label.
- `-repeat`: repeat index.
- `-summary-out`: optional summary JSON output path.
- `-manifest-out`: optional manifest JSON output path.

## Profile artifact metadata

The benchmark scripts can run selected profiled runs and store Java GC logs, Java JFR recordings, Go CPU profiles, Go heap profiles, and Go runtime metrics snapshots. `benchctl` does not create those service-side profile artifacts by itself; it carries their paths in configuration/result models so the run manifest can tie raw events and profile files together.

Supported artifact flags:

```bash
-profile-artifact java-gc-log:path/to/gc.log
-profile-artifact java-jfr:path/to/recording.jfr
-profile-artifact go-cpu-profile:path/to/cpu.pprof
-profile-artifact go-heap-profile:path/to/heap.pprof
-profile-artifact go-runtime-metrics:path/to/runtime-metrics.json
```

Convenience flags are also available and may be repeated:

```bash
-java-gc-log path/to/gc.log
-java-jfr path/to/recording.jfr
-go-cpu-profile path/to/cpu.pprof
-go-heap-profile path/to/heap.pprof
-go-runtime-metrics path/to/runtime-metrics.json
```

When any profile artifact is provided, `-manifest-out` is required so the artifacts are tied to a manifest.

## Output policy

`benchctl` writes raw event data and optional JSON metadata files only. It does not publish benchmark conclusions. Later analysis steps may consume the JSONL and manifest files.
