#!/usr/bin/env bash
set -euo pipefail

TARGET_RATES="${HEADROOM_TARGET_RATES_CSV:-analysis/output/target-rates.csv}"
RAW_SUMMARY="${HEADROOM_RAW_SUMMARY_CSV:-analysis/output/raw-summary.csv}"
SATURATION="${HEADROOM_SATURATION_CSV:-analysis/output/loadgen-saturation.csv}"
OUTPUT="${HEADROOM_OUTPUT_CSV:-analysis/output/headroom-control.csv}"
MIN_MULTIPLIER="${HEADROOM_MIN_MULTIPLIER:-1.25}"

export TARGET_RATES RAW_SUMMARY SATURATION OUTPUT MIN_MULTIPLIER

python3 <<'PY'
import csv
import os
import re
import sys
from decimal import Decimal, InvalidOperation
from pathlib import Path

target_rates = Path(os.environ["TARGET_RATES"])
raw_summary = Path(os.environ["RAW_SUMMARY"])
saturation_csv = Path(os.environ["SATURATION"])
output = Path(os.environ["OUTPUT"])
min_multiplier_text = os.environ["MIN_MULTIPLIER"]

HEADER = [
    "status",
    "reason",
    "minMultiplier",
    "requiredRate",
    "controlThroughput",
    "controlRate",
    "controlSourceFile",
    "controlSaturationStatus",
    "controlSaturationReason",
]

def error(message):
    print(f"headroom-control: error: {message}", file=sys.stderr)
    raise SystemExit(2)

def parse_decimal(value, context):
    text = str(value).strip()
    if text == "":
        error(f"{context} is empty")
    try:
        parsed = Decimal(text)
    except InvalidOperation:
        error(f"{context} is not numeric: {text}")
    return parsed

def decimal_text(value):
    if value is None:
        return ""
    text = format(value.normalize(), "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return "0" if text in {"", "-0"} else text

def read_dicts(path):
    if not path.is_file():
        error(f"missing input file: {path}")
    try:
        with path.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            if reader.fieldnames is None:
                error(f"missing header in {path}")
            return reader.fieldnames, list(reader)
    except OSError as exc:
        error(f"cannot read {path}: {exc}")

def require_columns(header, path, columns):
    missing = [name for name in columns if name not in header]
    if missing:
        error(f"missing required columns in {path}: {', '.join(missing)}")

def write_row(row):
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(HEADER)
        writer.writerow(row)

def source_keys(value):
    normalized = str(value).replace("\\", "/")
    keys = {normalized, os.path.basename(normalized)}
    if normalized.startswith("./"):
        keys.add(normalized[2:])
    return keys

def repeat_text(value):
    text = str(value).strip()
    if text.startswith("r"):
        text = text[1:]
    if not re.fullmatch(r"[0-9]+", text):
        error(f"control repeat is not an integer: {value}")
    return str(int(text))

def expected_loadgen_path(raw_file, repeat):
    base = os.path.basename(raw_file)
    if base.endswith(".jsonl"):
        base = base[:-6]
    suffix = f"_r{repeat}"
    if base.endswith(suffix):
        prefix = base[:-len(suffix)]
    else:
        match = re.search(r"_r[0-9]+$", base)
        prefix = base[:match.start()] if match else base
    return f"artifacts/process/{prefix}_loadgen_r{repeat}.csv"

def parse_rate_from_source(source):
    matches = re.findall(r"rate([0-9]+)", os.path.basename(source))
    return matches[-1] if matches else ""

multiplier = parse_decimal(min_multiplier_text, "HEADROOM_MIN_MULTIPLIER")
if multiplier <= 0:
    error("HEADROOM_MIN_MULTIPLIER must be greater than zero")

target_header, target_rows = read_dicts(target_rates)
require_columns(target_header, target_rates, ["status", "rate90"])

max_rate90 = None
for row_number, row in enumerate(target_rows, start=2):
    if row.get("status", "").strip().lower() != "pass":
        continue
    rate90 = parse_decimal(row.get("rate90", ""), f"{target_rates} row {row_number} rate90")
    if max_rate90 is None or rate90 > max_rate90:
        max_rate90 = rate90

if max_rate90 is None:
    write_row([
        "blocked",
        "no passing target-rate rows",
        decimal_text(multiplier),
        "",
        "",
        "",
        "",
        "",
        "",
    ])
    print("headroom-control: blocked")
    raise SystemExit(0)

required_rate = max_rate90 * multiplier

sat_header, sat_rows = read_dicts(saturation_csv)
require_columns(sat_header, saturation_csv, ["file", "status", "reason"])

saturation_by_key = {}
for row in sat_rows:
    source = row.get("file", "").strip()
    if source == "":
        continue
    for key in source_keys(source):
        saturation_by_key[key] = row

raw_header, raw_rows = read_dicts(raw_summary)
require_columns(raw_header, raw_summary, ["file", "service", "variant", "repeat", "throughput"])

best = None

for row_number, row in enumerate(raw_rows, start=2):
    if row.get("service", "").strip() != "control":
        continue
    if row.get("variant", "").strip() != "fast-echo":
        continue

    throughput = parse_decimal(row.get("throughput", ""), f"{raw_summary} row {row_number} throughput")
    source = row.get("file", "").strip()
    repeat = repeat_text(row.get("repeat", ""))
    expected = expected_loadgen_path(source, repeat)

    saturation = None
    for key in source_keys(expected):
        saturation = saturation_by_key.get(key)
        if saturation is not None:
            break

    if saturation is None:
        continue
    if saturation.get("status", "").strip().lower() != "pass":
        continue

    candidate = {
        "throughput": throughput,
        "source": source,
        "rate": parse_rate_from_source(source),
        "saturationStatus": saturation.get("status", ""),
        "saturationReason": saturation.get("reason", ""),
    }
    if best is None or throughput > best["throughput"]:
        best = candidate

if best is None:
    write_row([
        "fail",
        "no eligible control throughput",
        decimal_text(multiplier),
        decimal_text(required_rate),
        "",
        "",
        "",
        "",
        "",
    ])
    print("headroom-control: fail")
    raise SystemExit(1)

if best["throughput"] >= required_rate:
    write_row([
        "pass",
        "control throughput meets required headroom",
        decimal_text(multiplier),
        decimal_text(required_rate),
        decimal_text(best["throughput"]),
        best["rate"],
        best["source"],
        best["saturationStatus"],
        best["saturationReason"],
    ])
    print("headroom-control: pass")
    raise SystemExit(0)

write_row([
    "fail",
    "control throughput below required headroom",
    decimal_text(multiplier),
    decimal_text(required_rate),
    decimal_text(best["throughput"]),
    best["rate"],
    best["source"],
    best["saturationStatus"],
    best["saturationReason"],
])
print("headroom-control: fail")
raise SystemExit(1)
PY
