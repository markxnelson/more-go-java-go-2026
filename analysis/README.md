# Analysis helpers

These scripts inspect benchmark artifacts produced by the benchmark harness. They are intentionally conservative: they prepare inventories and validation summaries, but they do **not** fabricate measurements or write article conclusions.

Run all commands from the package root unless noted.

## Inputs

The normal benchmark matrix writes:

- `artifacts/raw/*.jsonl` - raw per-request event streams
- `artifacts/summary/*.json` - per-cell summary JSON files
- `artifacts/process/*_service_*.csv` - service process samples
- `artifacts/process/*_loadgen_*.csv` - load-generator process samples
- `manifests/environment.json` - environment capture
- `manifests/java-runtimes.json` - Java runtime inventory, when captured
- `manifests/matrix-cells.csv` - matrix cell manifest

Profiled runs may also write profile artifacts and a profile manifest. The profile helper accepts common manifest column names for:

- Java GC logs
- Java JFR recordings
- Go CPU profiles
- Go heap profiles
- Go runtime metrics snapshots

The profile helper inventories referenced files and marks whether each referenced artifact exists. It does not parse profile payloads or invent profile-derived numbers.

## Process sample format

New process samples should use canonical CSV, including load-generator process samples.

Canonical schema:

- `timestampUnixNano`
- `pid`
- `rssKiB`
- `vsizeKiB`
- `userTicks`
- `systemTicks`
- `threads`
- `fdCount`

`scripts/sample-process.sh` writes this header once and then appends one CSV row per sample.

Field sources:

- `timestampUnixNano` - nanosecond wall-clock time
- `rssKiB`, `vsizeKiB`, `threads` - `/proc/<pid>/status` where available
- `userTicks`, `systemTicks` - `/proc/<pid>/stat`
- `fdCount` - `/proc/<pid>/fd`

Some already-saved artifacts may still contain legacy JSON Lines process samples from earlier checkpointed runs. Analysis helpers that consume load-generator process samples must tolerate those legacy files until they are naturally replaced by fresh canonical CSV artifacts.

## Outputs

By default, generated analysis files are written under `analysis/output/`.

Common outputs:

- `analysis/output/inventory.json`
- `analysis/output/raw-summary.csv`
- `analysis/output/loadgen-saturation.csv`
- `analysis/output/target-rates.csv`
- `analysis/output/profiles-summary.csv`
- `analysis/output/raw-artifacts-check.csv`
- `analysis/output/headroom-control.csv`

## Scripts

### `prepare-artifacts.sh`

Builds a compact inventory at `analysis/output/inventory.json`.

Environment overrides:

- `ARTIFACTS_DIR` - default `artifacts`
- `MANIFESTS_DIR` - default `manifests`
- `OUTPUT_DIR` - default `analysis/output`

### `summarize-inventory.sh`

Prints `analysis/output/inventory.json`. If it does not exist, the script runs `prepare-artifacts.sh` first.

### `check-raw-artifacts.sh`

Checks raw JSONL files for readability, valid JSON, duplicate JSON object fields, and object-shaped event lines.

Output:

- `analysis/output/raw-artifacts-check.csv`

The script exits nonzero if any raw artifact is malformed. Missing raw files are reported as a warning row and exit successfully, because some setup-only workflows may run before a benchmark has produced raw data.

Environment overrides:

- `RAW_DIR` - default `artifacts/raw`
- `OUTPUT_DIR` - default `analysis/output`

### `summarize-raw.sh`

Summarizes raw JSONL request events into `analysis/output/raw-summary.csv`.

Output columns:

- `file`
- `service`
- `variant`
- `cell`
- `repeat`
- `count`
- `errors`
- `status2xx`
- `status4xx`
- `status5xx`
- `throughput`
- `p50`
- `p90`
- `p95`
- `p99`
- `maxLatencyMicros`

Warmup events are excluded when the raw stream marks them with common warmup fields such as `warmup`, `isWarmup`, `phase`, `stage`, `event`, or `kind`.

Throughput is computed from `durationNanos` in the matching summary JSON when available. If that field is not present, the script falls back to the span between event timestamps.

Environment overrides:

- `RAW_DIR` - default `artifacts/raw`
- `SUMMARY_DIR` - default `artifacts/summary`
- `OUTPUT_DIR` - default `analysis/output`

### `check-loadgen-saturation.sh`

Reads `artifacts/process/*_loadgen_*.csv` and writes `analysis/output/loadgen-saturation.csv`.

Supported input formats:

1. Canonical CSV with header:
   - `timestampUnixNano`
   - `pid`
   - `rssKiB`
   - `vsizeKiB`
   - `userTicks`
   - `systemTicks`
   - `threads`
   - `fdCount`
2. Legacy JSON Lines from already-saved checkpointed runs, with fields such as:
   - `timestampUtc`
   - `elapsedSeconds`
   - `rssKb`
   - `vszKb`
   - `cpuPercent`
   - `threads`
   - `fdCount`

Output columns:

- `file`
- `samples`
- `intervals`
- `maxCpuPercent`
- `avgCpuPercent`
- `maxRssKiB`
- `maxThreads`
- `maxFdCount`
- `status`
- `reason`

For canonical CSV, CPU percent is computed from adjacent samples:

- CPU tick delta is `delta(userTicks + systemTicks)`
- elapsed seconds is `delta(timestampUnixNano) / 1_000_000_000`
- CPU percent is `tickDelta / CLK_TCK / elapsedSeconds * 100`

`CLK_TCK` is detected with `getconf CLK_TCK` and defaults to `100` if unavailable.

For legacy JSON Lines, CPU tick counters were not captured, so the analyzer computes maximum and average CPU from the recorded `cpuPercent` samples.

Status rules:

- `pass` - parsed successfully and maximum CPU does not exceed the limit
- `fail` - malformed, unreadable, missing required fields, or CPU exceeds the limit
- `warn` - fewer than two data samples
- `warn` - no matching load-generator process files found

A missing set of load-generator files is not a hard error because very small proof runs may not have load-generator samples yet.

Defaults:

- `LOADGEN_CPU_LIMIT_PERCENT=80`

Environment overrides:

- `PROCESS_DIR` - default `artifacts/process`
- `OUTPUT_DIR` - default `analysis/output`
- `LOADGEN_CPU_LIMIT_PERCENT` - default `80`

The script exits nonzero only when at least one analyzed file has status `fail`.

### `select-target-rates.sh`

Reads:

- `analysis/output/raw-summary.csv`
- `analysis/output/loadgen-saturation.csv`

Writes:

- `analysis/output/target-rates.csv`

The selector groups observations by:

- service
- variant
- fixture
- CPU shape
- concurrency

Cell parsing is anchored from the right side of the cell name, so fixture names may contain hyphens.

Accepted cell forms:

- `<fixture>-c<concurrency>-rate<rate>` - legacy/no-affinity form, `cpuShape=all`
- `<fixture>-cpu<shape>-c<concurrency>-rate<rate>` - CPU-shaped form

For each group, the selector prefers passing closed-loop `rate0` observations whose matching load-generator saturation row is `pass`.

If no passing closed-loop row exists, the selector may use an eligible conservative fixed-rate probe when:

- load-generator saturation is `pass`
- request errors are zero
- all requests are `2xx`
- measured throughput is at least `RATE_SELECTION_MIN_PROBE_EFFICIENCY * requestedRate`

Defaults:

- `RATE_SELECTION_MIN_PROBE_EFFICIENCY=0.95`

Blocked rows are valid evidence that target-rate publication should not proceed for that slice without new artifacts or manual review.

Environment overrides:

- `RAW_SUMMARY` - default `analysis/output/raw-summary.csv`
- `LOADGEN_SATURATION` - default `analysis/output/loadgen-saturation.csv`
- `OUTPUT` - default `analysis/output/target-rates.csv`
- `RATE_SELECTION_MIN_PROBE_EFFICIENCY` - default `0.95`

### `summarize-profiles.sh`

Inventories profile artifacts and writes `analysis/output/profiles-summary.csv`.

The script first looks for profile manifests under `manifests/` using names containing `profile` and ending in `.csv`. It accepts common profile artifact column names, including:

- `javaGcLogArtifact`
- `javaJfrArtifact`
- `goCpuProfileArtifact`
- `goHeapProfileArtifact`
- `goRuntimeMetricsArtifact`

It also accepts several shorter aliases such as `jfrArtifact`, `cpuProfileArtifact`, and `metricsArtifact`.

If no profile manifest exists, the script scans `artifacts/profiles/` and writes `warn` rows for unmanifested profile-like files. Profile artifacts should be tied to manifests for publication evidence.

Environment overrides:

- `MANIFESTS_DIR` - default `manifests`
- `PROFILE_ARTIFACTS_DIR` - default `artifacts/profiles`
- `OUTPUT_DIR` - default `analysis/output`

### `check-headroom-control.sh`

Checks fast-echo headroom-control outputs against selected target rates.

Inputs:

- `analysis/output/target-rates.csv`
- `analysis/output/raw-summary.csv`
- `analysis/output/loadgen-saturation.csv`

Output:

- `analysis/output/headroom-control.csv`

Defaults:

- `HEADROOM_MIN_MULTIPLIER=1.25`

Environment overrides:

- `HEADROOM_TARGET_RATES_CSV`
- `HEADROOM_RAW_SUMMARY_CSV`
- `HEADROOM_SATURATION_CSV`
- `HEADROOM_OUTPUT_CSV`
- `HEADROOM_MIN_MULTIPLIER`

## Typical workflow

```bash
./analysis/prepare-artifacts.sh
./analysis/check-raw-artifacts.sh
./analysis/summarize-raw.sh
./analysis/check-loadgen-saturation.sh
./analysis/select-target-rates.sh
./analysis/summarize-profiles.sh
```

For isolated headroom-control artifacts:

```bash
RAW_DIR=artifacts/control/headroom/raw \
SUMMARY_DIR=artifacts/control/headroom/summary \
OUTPUT_DIR=analysis/output/headroom \
./analysis/summarize-raw.sh

PROCESS_DIR=artifacts/control/headroom/process \
OUTPUT_DIR=analysis/output/headroom \
./analysis/check-loadgen-saturation.sh
```

Then run headroom control with explicit input paths:

```bash
HEADROOM_TARGET_RATES_CSV=analysis/output/target-rates.csv \
HEADROOM_RAW_SUMMARY_CSV=analysis/output/headroom/raw-summary.csv \
HEADROOM_SATURATION_CSV=analysis/output/headroom/loadgen-saturation.csv \
HEADROOM_OUTPUT_CSV=analysis/output/headroom/headroom-control.csv \
./analysis/check-headroom-control.sh
```

## Requirements

- Bash
- Python 3
- `getconf`, optional for CPU tick frequency detection
- Linux `/proc` for `scripts/sample-process.sh`

## Notes

- These helpers do not modify benchmark source code.
- These helpers do not start services or load generators.
- These helpers do not include old artifacts, caches, build outputs, or extracted runtimes.
- Use clean manifests and freshly generated analysis outputs for publication evidence.
