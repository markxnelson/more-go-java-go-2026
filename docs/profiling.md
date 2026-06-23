# Profiling

The package is structured to support selected profiled runs. Profiling is optional for every matrix cell, but any profiled run must be tied to a manifest.

## Supported Profiling Artifacts

Java service runs may capture:

- GC logs
- JFR recordings

Go service runs may capture:

- CPU profiles
- Heap profiles
- Runtime metrics snapshots

## Expected Artifact Locations

Use these directories for generated profiling material:

- `artifacts/logs/` for Java GC logs and service logs
- `artifacts/profiles/` for JFR, Go CPU profiles, and Go heap profiles
- `artifacts/process/` for process resource samples
- `artifacts/raw/` for raw load-generator output
- `artifacts/summary/` for derived summaries
- `artifacts/env/` for captured environment information

## Manifest Linkage

Each selected profiled run should have a manifest entry that records:

- Timestamp
- Service name
- Runtime variant
- Fixture name
- Concurrency
- Rate or closed-loop setting
- Repeat number
- Service PID when available
- Raw artifact path
- Summary artifact path
- Process artifact paths
- Profile artifact paths
- Runtime metrics snapshot paths
- GC log or JFR paths for Java when enabled

Do not create profile entries for files that do not exist. Do not fabricate measurements or profile summaries.

## Java Notes

Use runtime flags appropriate for the selected JDK. Examples of artifact categories:

- GC log: `artifacts/logs/<run-id>-gc.log`
- JFR recording: `artifacts/profiles/<run-id>.jfr`

Keep JFR files out of source control.

## Go Notes

Use normal Go profiling mechanisms for selected runs. Examples of artifact categories:

- CPU profile: `artifacts/profiles/<run-id>-cpu.pprof`
- Heap profile: `artifacts/profiles/<run-id>-heap.pprof`
- Runtime metrics snapshot: `artifacts/profiles/<run-id>-runtime-metrics.json`

Keep profile files out of source control.
