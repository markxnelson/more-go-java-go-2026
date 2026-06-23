# Artifact Policy

This source package tracks source, documentation, fixtures, manifest templates, and empty output directories only.

## Do Not Commit

Do not commit generated or downloaded material such as:

- Benchmark result JSON, CSV, or JSONL files
- Raw load-generator output
- Summary files
- Process samples
- Java GC logs
- Java JFR recordings
- Go CPU profiles
- Go heap profiles
- Go runtime metrics snapshots
- Extracted JDK or runtime payloads
- Maven, Go, or tool caches
- Build output such as `target/`, `build/`, or binaries

## Output Directories

Generated files should be written under:

- `artifacts/env/`
- `artifacts/logs/`
- `artifacts/materialization/`
- `artifacts/process/`
- `artifacts/profiles/`
- `artifacts/raw/`
- `artifacts/summary/`
- `artifacts/tmp/`
- `analysis/output/`

Each directory contains a `.gitkeep` placeholder so the package structure is available before any run.

## Manifest Requirement

Any profiled or benchmarked run should have a manifest that identifies:

- Service implementation
- Runtime variant
- Fixture
- Concurrency
- Rate limit or open-loop setting
- Repeat number
- Process identifiers when available
- Paths to generated raw, summary, process, log, profile, and metrics artifacts

Do not fabricate measurements. If no run was executed, leave the artifact directories empty.

## Publication Guardrails

Benchmark publication cells must include enough artifact evidence to show that the measured service, not the load generator, was the limiting factor.

Load-generator process samples should be captured in canonical CSV form with this schema:

- `timestampUnixNano`
- `pid`
- `rssKiB`
- `vsizeKiB`
- `userTicks`
- `systemTicks`
- `threads`
- `fdCount`

Publication benchmark cells are not acceptable when load-generator CPU exceeds 80% in the saturation analysis, unless the cell is explicitly labeled as a load-generator limit test.

Use `analysis/check-loadgen-saturation.sh` to produce `analysis/output/loadgen-saturation.csv` and retain that CSV with the rest of the publication evidence set.
