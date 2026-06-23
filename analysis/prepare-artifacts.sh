#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/artifacts}"
MANIFESTS_DIR="${MANIFESTS_DIR:-$ROOT_DIR/manifests}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/analysis/output}"
OUTPUT_FILE="$OUTPUT_DIR/inventory.json"

mkdir -p "$OUTPUT_DIR"

export ROOT_DIR ARTIFACTS_DIR MANIFESTS_DIR OUTPUT_FILE

python3 <<'PY'
import json
import os
from pathlib import Path

root = Path(os.environ["ROOT_DIR"])
artifacts = Path(os.environ["ARTIFACTS_DIR"])
manifests = Path(os.environ["MANIFESTS_DIR"])
output_file = Path(os.environ["OUTPUT_FILE"])

def rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(root.resolve()))
    except ValueError:
        return str(path)

def count(pattern: str, base: Path) -> int:
    if not base.exists():
        return 0
    return sum(1 for p in base.glob(pattern) if p.is_file())

def list_files(pattern: str, base: Path):
    if not base.exists():
        return []
    return sorted(rel(p) for p in base.glob(pattern) if p.is_file())

raw_dir = artifacts / "raw"
summary_dir = artifacts / "summary"
process_dir = artifacts / "process"
profiles_dir = artifacts / "profiles"

environment_manifest = manifests / "environment.json"
java_runtimes_manifest = manifests / "java-runtimes.json"
matrix_manifest = manifests / "matrix-cells.csv"

profile_manifests = []
if manifests.exists():
    profile_manifests = sorted(
        rel(p)
        for p in manifests.glob("*profile*.csv")
        if p.is_file()
    )

inventory = {
    "policy": "artifact inventory only; no performance interpretation",
    "paths": {
        "artifactsDir": rel(artifacts),
        "manifestsDir": rel(manifests),
        "outputFile": rel(output_file),
    },
    "counts": {
        "rawJsonlFiles": count("*.jsonl", raw_dir),
        "summaryJsonFiles": count("*.json", summary_dir),
        "serviceProcessCsvFiles": sum(
            1 for p in process_dir.glob("*_service_*.csv")
            if process_dir.exists() and p.is_file()
        ),
        "loadgenProcessCsvFiles": sum(
            1 for p in process_dir.glob("*_loadgen_*.csv")
            if process_dir.exists() and p.is_file()
        ),
        "profileLikeFiles": sum(
            1 for p in profiles_dir.rglob("*")
            if profiles_dir.exists() and p.is_file()
        ),
        "profileManifestCsvFiles": len(profile_manifests),
    },
    "manifests": {
        "environmentPresent": environment_manifest.is_file(),
        "javaRuntimesPresent": java_runtimes_manifest.is_file(),
        "matrixCellsPresent": matrix_manifest.is_file(),
        "profileManifests": profile_manifests,
    },
    "files": {
        "rawJsonl": list_files("*.jsonl", raw_dir),
        "summaryJson": list_files("*.json", summary_dir),
        "loadgenProcessCsv": list_files("*_loadgen_*.csv", process_dir),
        "serviceProcessCsv": list_files("*_service_*.csv", process_dir),
    },
}

output_file.parent.mkdir(parents=True, exist_ok=True)
with output_file.open("w", encoding="utf-8") as handle:
    json.dump(inventory, handle, indent=2, sort_keys=True)
    handle.write("\n")

print("prepare-artifacts: pass")
PY
