#!/usr/bin/env bash
set -euo pipefail

RAW_SUMMARY="${RAW_SUMMARY:-analysis/output/raw-summary.csv}"
LOADGEN_SATURATION="${LOADGEN_SATURATION:-analysis/output/loadgen-saturation.csv}"
OUTPUT="${OUTPUT:-analysis/output/target-rates.csv}"
RATE_SELECTION_MIN_PROBE_EFFICIENCY="${RATE_SELECTION_MIN_PROBE_EFFICIENCY:-0.95}"

if [[ ! -s "$RAW_SUMMARY" ]]; then
  echo "select-target-rates: error: missing or empty required input: $RAW_SUMMARY" >&2
  exit 2
fi

if [[ ! -s "$LOADGEN_SATURATION" ]]; then
  echo "select-target-rates: error: missing or empty required input: $LOADGEN_SATURATION" >&2
  exit 2
fi

mkdir -p "$(dirname "$OUTPUT")"

export RAW_SUMMARY LOADGEN_SATURATION OUTPUT RATE_SELECTION_MIN_PROBE_EFFICIENCY

python3 <<'PY'
import csv
import math
import os
import re
import sys
from pathlib import Path

raw_summary = Path(os.environ["RAW_SUMMARY"])
loadgen_saturation = Path(os.environ["LOADGEN_SATURATION"])
output = Path(os.environ["OUTPUT"])
min_efficiency_text = os.environ["RATE_SELECTION_MIN_PROBE_EFFICIENCY"]

RAW_HEADER = [
    "file",
    "service",
    "variant",
    "cell",
    "repeat",
    "count",
    "errors",
    "status2xx",
    "status4xx",
    "status5xx",
    "throughput",
    "p50",
    "p90",
    "p95",
    "p99",
    "maxLatencyMicros",
]

SAT_HEADER = [
    "file",
    "samples",
    "intervals",
    "maxCpuPercent",
    "avgCpuPercent",
    "maxRssKiB",
    "maxThreads",
    "maxFdCount",
    "status",
    "reason",
]

OUTPUT_HEADER = [
    "service",
    "variant",
    "fixture",
    "cpuShape",
    "concurrency",
    "peakThroughput",
    "rate25",
    "rate50",
    "rate75",
    "rate90",
    "status",
    "reason",
    "sourceFile",
]

CPU_CELL_RE = re.compile(r"^(.+)-cpu([0-9]+)-c([0-9]+)-rate([0-9]+)$")
LEGACY_CELL_RE = re.compile(r"^(.+)-c([0-9]+)-rate([0-9]+)$")

errors = []

def report(message):
    errors.append(message)
    print(f"select-target-rates: error: {message}", file=sys.stderr)

def read_rows(path, expected_header, kind):
    try:
        with path.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.reader(handle, strict=True)
            try:
                header = next(reader)
            except StopIteration:
                report(f"missing header in {kind}: {path}")
                return []

            if header != expected_header:
                report(
                    f"malformed header in {kind}: expected {','.join(expected_header)}; got {','.join(header)}"
                )

            rows = []
            for line_number, row in enumerate(reader, start=2):
                if len(row) != len(expected_header):
                    report(
                        f"malformed row in {kind} line {line_number}: expected {len(expected_header)} fields; got {len(row)}"
                    )
                    continue
                rows.append((line_number, dict(zip(expected_header, row))))
            return rows
    except OSError as exc:
        report(f"cannot read {kind} {path}: {exc}")
        return []
    except csv.Error as exc:
        report(f"malformed CSV in {kind} {path}: {exc}")
        return []

def parse_cell(cell):
    match = CPU_CELL_RE.fullmatch(cell)
    if match:
        fixture, cpu_shape, concurrency, rate = match.groups()
        return fixture, cpu_shape, concurrency, int(rate), rate

    match = LEGACY_CELL_RE.fullmatch(cell)
    if match:
        fixture, concurrency, rate = match.groups()
        return fixture, "all", concurrency, int(rate), rate

    return None

def parse_non_negative_int(value, field_name, path, line_number):
    if not re.fullmatch(r"[0-9]+", value or ""):
        report(f"non-integer {field_name} in {path} line {line_number}: {value}")
        return None
    return int(value)

def parse_non_negative_float(value, field_name, path, line_number):
    try:
        parsed = float(value)
    except ValueError:
        report(f"non-numeric {field_name} in {path} line {line_number}: {value}")
        return None
    if not math.isfinite(parsed) or parsed < 0:
        report(f"invalid {field_name} in {path} line {line_number}: {value}")
        return None
    return parsed

def basename(path):
    return os.path.basename(path.replace("\\", "/"))

def source_keys(value):
    normalized = str(value).replace("\\", "/")
    keys = {normalized, basename(normalized)}
    if normalized.startswith("./"):
        keys.add(normalized[2:])
    return keys

def raw_to_loadgen_path(raw_file, repeat):
    base = basename(raw_file)
    if base.endswith(".jsonl"):
        base = base[:-6]

    rep = repeat
    if rep.startswith("r"):
        rep = rep[1:]

    suffix = f"_r{rep}"
    if rep and base.endswith(suffix):
        prefix = base[:-len(suffix)]
    else:
        match = re.search(r"_r[0-9]+$", base)
        prefix = base[:match.start()] if match else base

    return f"artifacts/process/{prefix}_loadgen_r{rep}.csv"

def format_number(value):
    text = f"{value:.6f}".rstrip("0").rstrip(".")
    return text if text else "0"

def target_rate(peak, fraction):
    if peak <= 0:
        return 0
    return max(1, int(math.floor(peak * fraction)))

try:
    min_efficiency = float(min_efficiency_text)
    if not math.isfinite(min_efficiency) or min_efficiency < 0:
        raise ValueError()
except ValueError:
    print(
        "select-target-rates: error: RATE_SELECTION_MIN_PROBE_EFFICIENCY must be a finite non-negative number",
        file=sys.stderr,
    )
    sys.exit(2)

sat_by_key = {}
for line_number, row in read_rows(loadgen_saturation, SAT_HEADER, "load-generator saturation CSV"):
    source = row["file"].strip()
    status = row["status"].strip().lower()
    reason = row["reason"].strip()

    if source == "":
        report(f"missing file in load-generator saturation CSV line {line_number}")
        continue
    if status == "":
        report(f"missing status in load-generator saturation CSV line {line_number}")
        continue

    entry = {"status": status, "reason": reason}
    for key in source_keys(source):
        sat_by_key[key] = entry

seen = {}
closed_pass = {}
closed_block = {}
probe_pass = {}
probe_block = {}

for line_number, row in read_rows(raw_summary, RAW_HEADER, "raw summary CSV"):
    required_fields = ["file", "service", "variant", "cell", "repeat", "count", "errors", "status2xx", "throughput"]
    missing = [field for field in required_fields if row[field].strip() == ""]
    if missing:
        report(f"missing {', '.join(missing)} in raw summary CSV line {line_number}")
        continue

    parsed_cell = parse_cell(row["cell"].strip())
    if parsed_cell is None:
        report(f"malformed cell in raw summary CSV line {line_number}: {row['cell']}")
        continue

    fixture, cpu_shape, concurrency, requested_rate, requested_rate_text = parsed_cell

    count = parse_non_negative_int(row["count"], "count", raw_summary, line_number)
    error_count = parse_non_negative_int(row["errors"], "errors", raw_summary, line_number)
    status2xx = parse_non_negative_int(row["status2xx"], "status2xx", raw_summary, line_number)
    throughput = parse_non_negative_float(row["throughput"], "throughput", raw_summary, line_number)

    if count is None or error_count is None or status2xx is None or throughput is None:
        continue

    service = row["service"].strip()
    variant = row["variant"].strip()
    key = (service, variant, fixture, cpu_shape, concurrency)

    if key not in seen:
        seen[key] = {
            "service": service,
            "variant": variant,
            "fixture": fixture,
            "cpuShape": cpu_shape,
            "concurrency": concurrency,
            "firstSource": row["file"],
        }

    expected_loadgen = raw_to_loadgen_path(row["file"], row["repeat"])
    saturation = None
    for source_key in source_keys(expected_loadgen):
        saturation = sat_by_key.get(source_key)
        if saturation is not None:
            break

    if saturation is None:
        saturation = {
            "status": "missing",
            "reason": f"no matching load-generator saturation row for {expected_loadgen}",
        }

    if requested_rate == 0:
        if saturation["status"] == "pass":
            if key not in closed_pass or throughput > closed_pass[key]["throughput"]:
                closed_pass[key] = {
                    "throughput": throughput,
                    "source": row["file"],
                }
        elif key not in closed_block:
            closed_block[key] = (
                f"no passing closed-loop load-generator observation; "
                f"{saturation['status']}; {saturation['reason']}"
            )
        continue

    if saturation["status"] != "pass":
        probe_block.setdefault(
            key,
            f"load-generator saturation status was {saturation['status']}; {saturation['reason']}",
        )
        continue

    if error_count != 0:
        probe_block.setdefault(key, f"fixed-rate probe had errors: errors {error_count}")
        continue

    if status2xx != count:
        probe_block.setdefault(
            key,
            f"fixed-rate probe did not return all 2xx responses: status2xx {status2xx} != count {count}",
        )
        continue

    required_throughput = requested_rate * min_efficiency
    if throughput < required_throughput:
        probe_block.setdefault(
            key,
            (
                "fixed-rate probe throughput below conservative threshold: "
                f"throughput {format_number(throughput)} < requested_rate {requested_rate_text} "
                f"* efficiency {format_number(min_efficiency)}"
            ),
        )
        continue

    if key not in probe_pass or throughput > probe_pass[key]["throughput"]:
        probe_pass[key] = {
            "throughput": throughput,
            "source": row["file"],
        }

if errors:
    sys.exit(2)

rows = []
for key in sorted(seen.keys(), key=lambda item: (item[0], item[1], item[2], item[3], int(item[4]))):
    meta = seen[key]

    if key in closed_pass:
        selected = closed_pass[key]
        peak = selected["throughput"]
        rows.append([
            meta["service"],
            meta["variant"],
            meta["fixture"],
            meta["cpuShape"],
            meta["concurrency"],
            format_number(peak),
            target_rate(peak, 0.25),
            target_rate(peak, 0.50),
            target_rate(peak, 0.75),
            target_rate(peak, 0.90),
            "pass",
            "selected passing closed-loop rate0 observation",
            selected["source"],
        ])
        continue

    if key in probe_pass:
        selected = probe_pass[key]
        peak = selected["throughput"]
        rows.append([
            meta["service"],
            meta["variant"],
            meta["fixture"],
            meta["cpuShape"],
            meta["concurrency"],
            format_number(peak),
            target_rate(peak, 0.25),
            target_rate(peak, 0.50),
            target_rate(peak, 0.75),
            target_rate(peak, 0.90),
            "pass",
            "selected conservative fixed-rate probe",
            selected["source"],
        ])
        continue

    reason = closed_block.get(key)
    probe_reason = probe_block.get(key)

    if reason and probe_reason:
        reason = f"{reason}; no eligible conservative fixed-rate probe: {probe_reason}"
    elif probe_reason:
        reason = f"no closed-loop rate0 observation was eligible; no eligible conservative fixed-rate probe: {probe_reason}"
    elif not reason:
        reason = "no closed-loop rate0 observation was eligible"

    rows.append([
        meta["service"],
        meta["variant"],
        meta["fixture"],
        meta["cpuShape"],
        meta["concurrency"],
        "",
        "",
        "",
        "",
        "",
        "blocked",
        reason,
        meta["firstSource"],
    ])

try:
    with output.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(OUTPUT_HEADER)
        writer.writerows(rows)
except OSError as exc:
    print(f"select-target-rates: error: cannot write {output}: {exc}", file=sys.stderr)
    sys.exit(2)

print("select-target-rates: pass")
PY
