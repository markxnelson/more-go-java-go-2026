#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFESTS_DIR="${MANIFESTS_DIR:-$ROOT_DIR/manifests}"
PROFILE_ARTIFACTS_DIR="${PROFILE_ARTIFACTS_DIR:-$ROOT_DIR/artifacts/profiles}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/analysis/output}"
OUTPUT_CSV="$OUTPUT_DIR/profiles-summary.csv"

mkdir -p "$OUTPUT_DIR"

export ROOT_DIR MANIFESTS_DIR PROFILE_ARTIFACTS_DIR OUTPUT_CSV

python3 <<'PY'
import csv
import os
from pathlib import Path

root = Path(os.environ["ROOT_DIR"])
manifests_dir = Path(os.environ["MANIFESTS_DIR"])
profiles_dir = Path(os.environ["PROFILE_ARTIFACTS_DIR"])
output_csv = Path(os.environ["OUTPUT_CSV"])

HEADER = [
    "manifest",
    "row",
    "service",
    "variant",
    "cell",
    "repeat",
    "profileType",
    "artifactPath",
    "exists",
    "sizeBytes",
    "status",
    "reason",
]

PROFILE_COLUMNS = {
    "javaGcLog": [
        "javaGcLogArtifact",
        "javaGcLog",
        "gcLogArtifact",
        "gcLog",
        "java_gc_log",
    ],
    "javaJfr": [
        "javaJfrArtifact",
        "jfrArtifact",
        "jfrRecording",
        "javaJfr",
        "java_jfr",
    ],
    "goCpuProfile": [
        "goCpuProfileArtifact",
        "cpuProfileArtifact",
        "goCpuProfile",
        "go_cpu_profile",
    ],
    "goHeapProfile": [
        "goHeapProfileArtifact",
        "heapProfileArtifact",
        "goHeapProfile",
        "go_heap_profile",
    ],
    "goRuntimeMetrics": [
        "goRuntimeMetricsArtifact",
        "goMetricsArtifact",
        "runtimeMetricsArtifact",
        "metricsArtifact",
        "goRuntimeMetrics",
        "go_runtime_metrics",
    ],
}

META_COLUMNS = {
    "service": ["service", "resultService"],
    "variant": ["variant"],
    "cell": ["cell", "benchmarkCell", "matrixCell"],
    "repeat": ["repeat", "run", "iteration"],
}

def rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(root.resolve()))
    except ValueError:
        return str(path)

def resolve_artifact(value: str) -> Path:
    candidate = Path(value)
    if candidate.is_absolute():
        return candidate

    root_candidate = root / candidate
    if root_candidate.exists():
        return root_candidate

    profile_candidate = profiles_dir / candidate
    if profile_candidate.exists():
        return profile_candidate

    return root_candidate

def find_column(fieldnames, names):
    lowered = {name.lower(): name for name in fieldnames or []}
    for name in names:
        hit = lowered.get(name.lower())
        if hit is not None:
            return hit
    return None

def cell_value(row, fieldnames, names):
    column = find_column(fieldnames, names)
    if column is None:
        return ""
    return (row.get(column) or "").strip()

def classify_unmanifested(path: Path) -> str:
    lower = path.name.lower()
    if lower.endswith(".jfr"):
        return "javaJfr"
    if "gc" in lower and (lower.endswith(".log") or lower.endswith(".txt")):
        return "javaGcLog"
    if "cpu" in lower and (lower.endswith(".pprof") or lower.endswith(".prof")):
        return "goCpuProfile"
    if "heap" in lower and (lower.endswith(".pprof") or lower.endswith(".prof")):
        return "goHeapProfile"
    if "metric" in lower and lower.endswith(".json"):
        return "goRuntimeMetrics"
    return "profileArtifact"

rows = []

manifest_files = []
if manifests_dir.exists():
    manifest_files = sorted(
        p for p in manifests_dir.glob("*profile*.csv")
        if p.is_file()
    )

for manifest in manifest_files:
    try:
        with manifest.open("r", encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            if not reader.fieldnames:
                rows.append([
                    rel(manifest),
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "",
                    "false",
                    "0",
                    "fail",
                    "profile manifest has no header",
                ])
                continue

            for row_number, row in enumerate(reader, start=2):
                service = cell_value(row, reader.fieldnames, META_COLUMNS["service"])
                variant = cell_value(row, reader.fieldnames, META_COLUMNS["variant"])
                cell = cell_value(row, reader.fieldnames, META_COLUMNS["cell"])
                repeat = cell_value(row, reader.fieldnames, META_COLUMNS["repeat"])

                any_profile = False
                for profile_type, names in PROFILE_COLUMNS.items():
                    column = find_column(reader.fieldnames, names)
                    if column is None:
                        continue

                    value = (row.get(column) or "").strip()
                    if value == "":
                        continue

                    any_profile = True
                    artifact = resolve_artifact(value)
                    exists = artifact.is_file()
                    size = artifact.stat().st_size if exists else 0

                    rows.append([
                        rel(manifest),
                        str(row_number),
                        service,
                        variant,
                        cell,
                        repeat,
                        profile_type,
                        value,
                        "true" if exists else "false",
                        str(size),
                        "pass" if exists else "fail",
                        "referenced profile artifact exists" if exists else "referenced profile artifact is missing",
                    ])

                if not any_profile:
                    rows.append([
                        rel(manifest),
                        str(row_number),
                        service,
                        variant,
                        cell,
                        repeat,
                        "",
                        "",
                        "false",
                        "0",
                        "warn",
                        "manifest row has no recognized profile artifact columns populated",
                    ])
    except OSError as exc:
        rows.append([
            rel(manifest),
            "",
            "",
            "",
            "",
            "",
            "",
            "",
            "false",
            "0",
            "fail",
            f"cannot read profile manifest: {exc}",
        ])

if not manifest_files:
    if profiles_dir.exists():
        profile_files = sorted(p for p in profiles_dir.rglob("*") if p.is_file())
    else:
        profile_files = []

    if not profile_files:
        rows.append([
            "",
            "",
            "",
            "",
            "",
            "",
            "",
            "",
            "false",
            "0",
            "warn",
            "no profile manifest or profile artifacts found",
        ])
    else:
        for path in profile_files:
            rows.append([
                "",
                "",
                "",
                "",
                "",
                "",
                classify_unmanifested(path),
                rel(path),
                "true",
                str(path.stat().st_size),
                "warn",
                "profile-like artifact found without profile manifest tie",
            ])

with output_csv.open("w", encoding="utf-8", newline="") as handle:
    writer = csv.writer(handle, lineterminator="\n")
    writer.writerow(HEADER)
    writer.writerows(rows)

failures = [row for row in rows if row[10] == "fail"]
if failures:
    print(f"summarize-profiles: fail; see {rel(output_csv)}")
    raise SystemExit(1)

print(f"summarize-profiles: pass; wrote {rel(output_csv)}")
PY
