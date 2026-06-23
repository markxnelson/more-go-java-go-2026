#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAW_DIR="${RAW_DIR:-$ROOT_DIR/artifacts/raw}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/analysis/output}"
OUTPUT_CSV="$OUTPUT_DIR/raw-artifacts-check.csv"

mkdir -p "$OUTPUT_DIR"

export ROOT_DIR RAW_DIR OUTPUT_CSV

python3 <<'PY'
import csv
import json
import os
from pathlib import Path

root = Path(os.environ["ROOT_DIR"])
raw_dir = Path(os.environ["RAW_DIR"])
output_csv = Path(os.environ["OUTPUT_CSV"])

HEADER = [
    "file",
    "lines",
    "jsonObjects",
    "status",
    "reason",
]

def rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(root.resolve()))
    except ValueError:
        return str(path)

class DuplicateKeyError(ValueError):
    pass

def reject_duplicate_pairs(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise DuplicateKeyError(f"duplicate JSON field: {key}")
        out[key] = value
    return out

rows = []
any_fail = False

raw_files = sorted(raw_dir.glob("*.jsonl")) if raw_dir.exists() else []

if not raw_files:
    rows.append([
        str(raw_dir),
        "0",
        "0",
        "warn",
        "no raw JSONL files found",
    ])
else:
    for path in raw_files:
        lines = 0
        objects = 0
        status = "pass"
        reason = "ok"

        try:
            with path.open("r", encoding="utf-8") as handle:
                for line_number, line in enumerate(handle, start=1):
                    stripped = line.strip()
                    if stripped == "":
                        continue

                    lines += 1

                    try:
                        payload = json.loads(
                            stripped,
                            object_pairs_hook=reject_duplicate_pairs,
                        )
                    except DuplicateKeyError as exc:
                        status = "fail"
                        reason = f"line {line_number}: {exc}"
                        any_fail = True
                        break
                    except json.JSONDecodeError as exc:
                        status = "fail"
                        reason = f"line {line_number}: invalid JSON: {exc.msg}"
                        any_fail = True
                        break

                    if not isinstance(payload, dict):
                        status = "fail"
                        reason = f"line {line_number}: raw event is not a JSON object"
                        any_fail = True
                        break

                    objects += 1
        except OSError as exc:
            status = "fail"
            reason = f"cannot read file: {exc}"
            any_fail = True

        if status == "pass" and lines == 0:
            status = "warn"
            reason = "file contains no JSONL event lines"

        rows.append([
            rel(path),
            str(lines),
            str(objects),
            status,
            reason,
        ])

with output_csv.open("w", encoding="utf-8", newline="") as handle:
    writer = csv.writer(handle, lineterminator="\n")
    writer.writerow(HEADER)
    writer.writerows(rows)

if any_fail:
    print(f"check-raw-artifacts: fail; see {rel(output_csv)}")
    raise SystemExit(1)

print(f"check-raw-artifacts: pass; see {rel(output_csv)}")
PY
