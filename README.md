# More Go, Java, Go Benchmark Source Package

This repository contains the benchmark source package for the 2026 More Go, Java, Go article series. It includes the shared HTTP contract, Go and Java service implementations, the package-local load generator, validation fixtures, manifests, benchmark scripts, and analysis scripts.

It intentionally does **not** include heavyweight raw request streams, process samples, generated binaries, profile dumps, AOT cache binaries, extracted JDK runtime payloads, Maven/Go build output, or temporary run directories.

## Service Contract

The accepted service contract is:

- `GET /health`
- `HEAD /health`
- `POST /work`

`GET /health` returns exactly this JSON object, without extra fields:

    {"status":"ok"}

`HEAD /health` returns status `200` and no response body.

`POST /work` accepts a JSON object with these required fields:

- `requestId`
- `payloadSize`
- `seed`
- `extraWork`

Strict validation requirements are defined by the rules below and exercised by the shared validation fixtures. Both the Go and Java services should treat those rules and fixtures as the public contract for comparable behavior.

## Validation Rules

`POST /work` must reject:

- Invalid content type
- Invalid JSON
- Multiple JSON documents in one request body
- Decoded bodies larger than `4096` bytes
- Duplicate fields
- Unknown fields
- Missing required fields
- Quoted numeric strings
- Wrong scalar types
- Numeric bound violations

The decoded request body limit is `4096` bytes. Implementations must enforce this by reading at most `4097` bytes before JSON decode.

## Important Implementation Requirements

The benchmark source must preserve these requirements:

- The Java service must be real **Helidon SE WebServer** source.
- Helidon is pinned to `4.4.1` unless a newer version is explicitly verified during the task that changes it.
- The Java service must not use the JDK built-in HTTP server package.
- The Go and Java services must implement the same request validation behavior.
- Benchmark and profiling scripts must not fabricate measurements.

## Layout

- `fixtures/valid/` - accepted request examples
- `fixtures/errors/` - negative request examples
- `manifests/` - runtime and matrix manifest templates
- `artifacts/` - output directories for generated artifacts
- `docs/` - operating notes and validation expectations
- `analysis/output/` - output directory for locally generated analysis summaries

## Prerequisites

Typical tools are:

- Bash
- Go
- JDK 21 or newer
- Maven
- `curl`
- `jq` for local validation helpers
- `python3` for metadata checks

Use writable local caches when home caches are unavailable:

    export GOCACHE=/tmp/more-go-java-go-build-cache
    export GOMODCACHE=/tmp/more-go-java-go-mod-cache
    export MAVEN_OPTS="-Dmaven.repo.local=/tmp/more-go-java-go-m2"

## Artifact Policy

Generated artifacts belong under `artifacts/` and are ignored by Git. The benchmark scripts create output directories as needed. Do not commit raw benchmark output, process samples, GC logs, JFR recordings, Go profiles, runtime metric snapshots, extracted JDKs, binaries, AOT cache files, or temporary files.

## Profiling Support

The generated package is designed to support selected profiled runs with:

- Java GC logs
- Java JFR recordings
- Go CPU profiles
- Go heap profiles
- Go runtime metrics snapshots

Profiling artifacts must be tied to manifests. Do not fabricate measurements.

## Results and Raw Data

This repository publishes the benchmark code and harness, not the raw measurement dump. Raw request streams, process samples, profile dumps, generated result tables, and AOT cache binaries are intentionally excluded because they are large generated files and may contain machine-local paths. Regenerate those artifacts locally with the scripts in this package when you want to reproduce or extend the benchmark.
