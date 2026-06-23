#!/usr/bin/env bash
set -euo pipefail

PROCESS_DIR="${PROCESS_DIR:-artifacts/process}"
OUTPUT_DIR="${OUTPUT_DIR:-analysis/output}"
OUTPUT_CSV="$OUTPUT_DIR/loadgen-saturation.csv"
LOADGEN_CPU_LIMIT_PERCENT="${LOADGEN_CPU_LIMIT_PERCENT:-80}"

if ! [[ "$LOADGEN_CPU_LIMIT_PERCENT" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "loadgen-saturation: invalid LOADGEN_CPU_LIMIT_PERCENT='$LOADGEN_CPU_LIMIT_PERCENT'" >&2
  exit 2
fi

CLK_TCK="$(getconf CLK_TCK 2>/dev/null || true)"
if ! [[ "$CLK_TCK" =~ ^[1-9][0-9]*$ ]]; then
  CLK_TCK="100"
fi

mkdir -p "$OUTPUT_DIR"

export PROCESS_DIR OUTPUT_CSV LOADGEN_CPU_LIMIT_PERCENT CLK_TCK

python3 <<'PY'
import csv
import glob
import json
import os
import sys
from pathlib import Path

process_dir = os.environ["PROCESS_DIR"].rstrip("/")
output_csv = Path(os.environ["OUTPUT_CSV"])
limit = float(os.environ["LOADGEN_CPU_LIMIT_PERCENT"])
clk_tck = float(os.environ["CLK_TCK"])

HEADER = [
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

CANONICAL_HEADER = [
    "timestampUnixNano",
    "pid",
    "rssKiB",
    "vsizeKiB",
    "userTicks",
    "systemTicks",
    "threads",
    "fdCount",
]

ZERO_ROW = ["0.000000", "0.000000", 0, 0, 0]

def format_row(path, samples, intervals, max_cpu, avg_cpu, max_rss, max_threads, max_fd, status, reason):
    return [
        path,
        samples,
        intervals,
        f"{max_cpu:.6f}",
        f"{avg_cpu:.6f}",
        max_rss,
        max_threads,
        max_fd,
        status,
        reason,
    ]

def parse_non_negative_int(value, name, line_number):
    text = str(value).strip()
    if text == "":
        raise ValueError(f"line {line_number}: empty {name}")
    if not text.isdigit():
        raise ValueError(f"line {line_number}: non-numeric {name}")
    return int(text)

def parse_non_negative_number(value, name, line_number):
    text = str(value).strip()
    if text == "":
        raise ValueError(f"line {line_number}: empty {name}")
    number = float(text)
    if number < 0:
        raise ValueError(f"line {line_number}: negative {name}")
    return number

def summarize_canonical_csv(path):
    samples = 0
    intervals = 0
    max_cpu = 0.0
    total_elapsed = 0.0
    total_ticks = 0
    max_rss = 0
    max_threads = 0
    max_fd = 0
    prev_timestamp = None
    prev_ticks = None

    try:
        with open(path, "r", encoding="utf-8", newline="") as handle:
            reader = csv.reader(handle)
            try:
                header = next(reader)
            except StopIteration:
                return format_row(path, 0, 0, 0.0, 0.0, 0, 0, 0, "fail", "missing header")

            if header != CANONICAL_HEADER:
                return None

            for line_number, row in enumerate(reader, start=2):
                if len(row) == 0 or all(cell.strip() == "" for cell in row):
                    continue
                if len(row) != len(CANONICAL_HEADER):
                    return format_row(
                        path,
                        samples,
                        intervals,
                        max_cpu,
                        0.0 if total_elapsed <= 0 else (total_ticks / clk_tck / total_elapsed * 100.0),
                        max_rss,
                        max_threads,
                        max_fd,
                        "fail",
                        f"line {line_number}: expected 8 columns",
                    )

                try:
                    timestamp = parse_non_negative_int(row[0], "timestampUnixNano", line_number)
                    rss = parse_non_negative_int(row[2], "rssKiB", line_number)
                    user_ticks = parse_non_negative_int(row[4], "userTicks", line_number)
                    system_ticks = parse_non_negative_int(row[5], "systemTicks", line_number)
                    threads = parse_non_negative_int(row[6], "threads", line_number)
                    fd_count = parse_non_negative_int(row[7], "fdCount", line_number)
                except ValueError as exc:
                    return format_row(
                        path,
                        samples,
                        intervals,
                        max_cpu,
                        0.0 if total_elapsed <= 0 else (total_ticks / clk_tck / total_elapsed * 100.0),
                        max_rss,
                        max_threads,
                        max_fd,
                        "fail",
                        str(exc),
                    )

                ticks = user_ticks + system_ticks

                if prev_timestamp is not None:
                    elapsed = (timestamp - prev_timestamp) / 1_000_000_000.0
                    tick_delta = ticks - prev_ticks

                    if elapsed <= 0:
                        return format_row(
                            path,
                            samples,
                            intervals,
                            max_cpu,
                            0.0 if total_elapsed <= 0 else (total_ticks / clk_tck / total_elapsed * 100.0),
                            max_rss,
                            max_threads,
                            max_fd,
                            "fail",
                            f"line {line_number}: timestamp must increase between adjacent samples",
                        )

                    if tick_delta < 0:
                        return format_row(
                            path,
                            samples,
                            intervals,
                            max_cpu,
                            0.0 if total_elapsed <= 0 else (total_ticks / clk_tck / total_elapsed * 100.0),
                            max_rss,
                            max_threads,
                            max_fd,
                            "fail",
                            f"line {line_number}: CPU tick counters decreased between adjacent samples",
                        )

                    cpu_percent = tick_delta / clk_tck / elapsed * 100.0
                    max_cpu = max(max_cpu, cpu_percent)
                    total_elapsed += elapsed
                    total_ticks += tick_delta
                    intervals += 1

                samples += 1
                max_rss = max(max_rss, rss)
                max_threads = max(max_threads, threads)
                max_fd = max(max_fd, fd_count)
                prev_timestamp = timestamp
                prev_ticks = ticks

    except OSError as exc:
        return format_row(path, 0, 0, 0.0, 0.0, 0, 0, 0, "fail", f"cannot read file: {exc}")

    avg_cpu = (total_ticks / clk_tck / total_elapsed * 100.0) if total_elapsed > 0 else 0.0

    if samples < 2:
        status = "warn"
        reason = "fewer than two data samples"
    elif max_cpu > limit:
        status = "fail"
        reason = f"maxCpuPercent {max_cpu:.6f} exceeds limit {limit:.6f}"
    else:
        status = "pass"
        reason = "ok"

    return format_row(path, samples, intervals, max_cpu, avg_cpu, max_rss, max_threads, max_fd, status, reason)

def summarize_legacy_jsonl(path):
    samples = 0
    intervals = 0
    max_cpu = 0.0
    cpu_sum = 0.0
    max_rss = 0
    max_threads = 0
    max_fd = 0

    try:
        with open(path, "r", encoding="utf-8") as handle:
            first_non_empty = None
            for line_number, raw_line in enumerate(handle, start=1):
                line = raw_line.strip()
                if not line:
                    continue
                first_non_empty = (line_number, line)
                break

            if first_non_empty is None:
                return format_row(path, 0, 0, 0.0, 0.0, 0, 0, 0, "fail", "empty file")

            line_number, line = first_non_empty
            if not line.startswith("{"):
                return None

        with open(path, "r", encoding="utf-8") as handle:
            for line_number, raw_line in enumerate(handle, start=1):
                line = raw_line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError as exc:
                    return format_row(path, samples, intervals, max_cpu, 0.0 if samples == 0 else cpu_sum / samples, max_rss, max_threads, max_fd, "fail", f"line {line_number}: invalid JSON: {exc.msg}")

                if not isinstance(obj, dict):
                    return format_row(path, samples, intervals, max_cpu, 0.0 if samples == 0 else cpu_sum / samples, max_rss, max_threads, max_fd, "fail", f"line {line_number}: expected JSON object")

                required = ["cpuPercent", "rssKb", "threads", "fdCount"]
                for name in required:
                    if name not in obj:
                        return format_row(path, samples, intervals, max_cpu, 0.0 if samples == 0 else cpu_sum / samples, max_rss, max_threads, max_fd, "fail", f"line {line_number}: missing field {name}")

                try:
                    cpu = parse_non_negative_number(obj["cpuPercent"], "cpuPercent", line_number)
                    rss = parse_non_negative_int(obj["rssKb"], "rssKb", line_number)
                    threads = parse_non_negative_int(obj["threads"], "threads", line_number)
                    fd_count = parse_non_negative_int(obj["fdCount"], "fdCount", line_number)
                except (ValueError, TypeError) as exc:
                    return format_row(path, samples, intervals, max_cpu, 0.0 if samples == 0 else cpu_sum / max(samples, 1), max_rss, max_threads, max_fd, "fail", str(exc))

                samples += 1
                max_cpu = max(max_cpu, cpu)
                cpu_sum += cpu
                max_rss = max(max_rss, rss)
                max_threads = max(max_threads, threads)
                max_fd = max(max_fd, fd_count)

    except OSError as exc:
        return format_row(path, 0, 0, 0.0, 0.0, 0, 0, 0, "fail", f"cannot read file: {exc}")

    intervals = samples - 1 if samples >= 1 else 0
    avg_cpu = cpu_sum / samples if samples > 0 else 0.0

    if samples < 2:
        status = "warn"
        reason = "fewer than two data samples"
    elif max_cpu > limit:
        status = "fail"
        reason = f"maxCpuPercent {max_cpu:.6f} exceeds limit {limit:.6f}"
    else:
        status = "pass"
        reason = "ok"

    return format_row(path, samples, intervals, max_cpu, avg_cpu, max_rss, max_threads, max_fd, status, reason)

def summarize_file(path):
    canonical = summarize_canonical_csv(path)
    if canonical is not None:
        return canonical

    legacy = summarize_legacy_jsonl(path)
    if legacy is not None:
        return legacy

    return format_row(
        path,
        0,
        0,
        0.0,
        0.0,
        0,
        0,
        0,
        "fail",
        "malformed file: not canonical CSV and not legacy JSON Lines",
    )

files = sorted(glob.glob(os.path.join(process_dir, "*_loadgen_*.csv")))
rows = []

if not files:
    rows.append(
        format_row(
            os.path.join(process_dir, "*_loadgen_*.csv"),
            0,
            0,
            0.0,
            0.0,
            0,
            0,
            0,
            "warn",
            "no load-generator process files found",
        )
    )
else:
    rows = [summarize_file(path) for path in files]

with output_csv.open("w", encoding="utf-8", newline="") as handle:
    writer = csv.writer(handle, lineterminator="\n")
    writer.writerow(HEADER)
    writer.writerows(rows)

if any(row[8] == "fail" for row in rows):
    print(f"loadgen-saturation: fail; see {output_csv}", file=sys.stderr)
    sys.exit(1)

print("loadgen-saturation: pass")
PY
