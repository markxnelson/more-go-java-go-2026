#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW_DIR="${RAW_DIR:-$ROOT_DIR/artifacts/raw}"
SUMMARY_DIR="${SUMMARY_DIR:-$ROOT_DIR/artifacts/summary}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/analysis/output}"
OUTPUT_CSV="$OUTPUT_DIR/raw-summary.csv"

mkdir -p "$OUTPUT_DIR"

export ROOT_DIR RAW_DIR SUMMARY_DIR OUTPUT_CSV

python3 <<'PY'
import csv
import json
import math
import os
import re
import sys
from pathlib import Path

root = Path(os.environ["ROOT_DIR"])
raw_dir = Path(os.environ["RAW_DIR"])
summary_dir = Path(os.environ["SUMMARY_DIR"])
output_csv = Path(os.environ["OUTPUT_CSV"])

HEADER = [
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

WARMUP_TEXT = {"warmup", "warm-up", "warm_up"}

def number(value):
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        if math.isfinite(float(value)):
            return float(value)
        return None
    if isinstance(value, str):
        text = value.strip()
        if text == "":
            return None
        try:
            parsed = float(text)
        except ValueError:
            return None
        if math.isfinite(parsed):
            return parsed
    return None

def text(value):
    if value is None:
        return ""
    return str(value)

def is_truthy_marker(value):
    if value is True:
        return True
    if value == 1:
        return True
    if isinstance(value, str):
        lowered = value.strip().lower()
        return lowered in {"true", "yes", "1", "warmup", "warm-up", "warm_up"}
    return False

def is_warmup(event):
    for key in ("warmup", "isWarmup", "is_warmup", "warm_up"):
        if is_truthy_marker(event.get(key)):
            return True

    for key in ("phase", "stage", "event", "kind", "type", "marker", "mode", "name"):
        value = event.get(key)
        if isinstance(value, str):
            lowered = value.strip().lower()
            if lowered in WARMUP_TEXT or lowered.startswith("warmup") or lowered.startswith("warm-up"):
                return True

    return False

def first_number(event, names):
    for name in names:
        value = number(event.get(name))
        if value is not None:
            return value
    return None

def latency_micros(event):
    micros = first_number(event, (
        "latencyMicros",
        "latency_us",
        "latencyMicroseconds",
        "durationMicros",
        "duration_us",
        "elapsedMicros",
        "responseTimeMicros",
    ))
    if micros is not None:
        return max(0, int(micros))

    nanos = first_number(event, (
        "latencyNanos",
        "latency_ns",
        "durationNanos",
        "duration_ns",
        "elapsedNanos",
        "responseTimeNanos",
    ))
    if nanos is not None:
        return max(0, int(nanos / 1000))

    millis = first_number(event, (
        "latencyMillis",
        "latencyMs",
        "latency_ms",
        "durationMillis",
        "durationMs",
        "duration_ms",
        "elapsedMillis",
        "responseTimeMillis",
    ))
    if millis is not None:
        return max(0, int(millis * 1000))

    return None

def timestamp_nanos(event):
    return first_number(event, (
        "timestampUnixNano",
        "timestampUnixNanos",
        "timestamp_ns",
        "endUnixNano",
        "completedUnixNano",
        "scheduledUnixNano",
    ))

def status_code(event):
    for key in ("status", "statusCode", "httpStatus", "code"):
        value = number(event.get(key))
        if value is not None:
            return int(value)
    return None

def error_flag(event, status):
    if event.get("error") is True or event.get("failed") is True:
        return True
    if event.get("ok") is False or event.get("success") is False:
        return True
    if status is not None and status >= 400:
        return True
    return False

def parse_name(path: Path):
    base = path.name
    stem = base[:-6] if base.endswith(".jsonl") else path.stem
    repeat = ""

    match = re.search(r"_r([0-9]+)$", stem)
    if match:
        repeat = match.group(1)
        stem_without_repeat = stem[:match.start()]
    else:
        stem_without_repeat = stem

    parts = stem_without_repeat.split("_", 2)
    if len(parts) == 3:
        return parts[0], parts[1], parts[2], repeat

    return "", "", stem_without_repeat, repeat

def percentile(sorted_values, pct):
    if not sorted_values:
        return ""
    index = math.ceil((pct / 100.0) * len(sorted_values)) - 1
    index = max(0, min(index, len(sorted_values) - 1))
    return str(sorted_values[index])

def format_float(value):
    if value is None:
        return ""
    rendered = f"{value:.6f}".rstrip("0").rstrip(".")
    return rendered if rendered else "0"

def summary_duration_nanos(raw_file: Path):
    summary_path = summary_dir / (raw_file.stem + ".json")
    if not summary_path.is_file():
        return None
    try:
        with summary_path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return None
    value = number(payload.get("durationNanos"))
    if value is not None and value > 0:
        return value
    return None

raw_files = sorted(raw_dir.glob("*.jsonl")) if raw_dir.exists() else []

with output_csv.open("w", encoding="utf-8", newline="") as handle:
    writer = csv.writer(handle, lineterminator="\n")
    writer.writerow(HEADER)

    for raw_file in raw_files:
        name_service, name_variant, name_cell, name_repeat = parse_name(raw_file)

        service = ""
        variant = ""
        cell = ""
        repeat = ""
        count = 0
        errors = 0
        status2xx = 0
        status4xx = 0
        status5xx = 0
        latencies = []
        timestamps = []

        try:
            with raw_file.open("r", encoding="utf-8") as input_handle:
                for line in input_handle:
                    stripped = line.strip()
                    if stripped == "":
                        continue

                    try:
                        event = json.loads(stripped)
                    except json.JSONDecodeError as exc:
                        raise SystemExit(
                            f"summarize-raw: error: invalid JSON in {raw_file} line {exc.lineno}: {exc.msg}"
                        )

                    if not isinstance(event, dict):
                        continue

                    if is_warmup(event):
                        continue

                    if not service:
                        service = text(event.get("service"))
                    if not variant:
                        variant = text(event.get("variant"))
                    if not cell:
                        cell = text(event.get("cell"))
                    if not repeat:
                        repeat = text(event.get("repeat") or event.get("iteration") or event.get("run"))

                    count += 1

                    status = status_code(event)
                    if error_flag(event, status):
                        errors += 1

                    if status is not None:
                        if 200 <= status < 300:
                            status2xx += 1
                        elif 400 <= status < 500:
                            status4xx += 1
                        elif 500 <= status < 600:
                            status5xx += 1

                    latency = latency_micros(event)
                    if latency is not None:
                        latencies.append(latency)

                    ts = timestamp_nanos(event)
                    if ts is not None:
                        timestamps.append(ts)
        except OSError as exc:
            raise SystemExit(f"summarize-raw: error: cannot read {raw_file}: {exc}")

        service = service or name_service
        variant = variant or name_variant
        cell = cell or name_cell
        repeat = repeat or name_repeat

        duration_nanos = summary_duration_nanos(raw_file)
        if duration_nanos is None and len(timestamps) >= 2:
            span = max(timestamps) - min(timestamps)
            if span > 0:
                duration_nanos = span

        throughput = ""
        if duration_nanos is not None and duration_nanos > 0:
            throughput = format_float(count / (duration_nanos / 1_000_000_000.0))

        latencies.sort()
        max_latency = str(latencies[-1]) if latencies else ""

        writer.writerow([
            raw_file.name,
            service,
            variant,
            cell,
            repeat,
            str(count),
            str(errors),
            str(status2xx),
            str(status4xx),
            str(status5xx),
            throughput,
            percentile(latencies, 50),
            percentile(latencies, 90),
            percentile(latencies, 95),
            percentile(latencies, 99),
            max_latency,
        ])
PY

echo "summarize-raw: pass"
