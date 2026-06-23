#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

manifest="${1:-}"

if [[ -z "${manifest}" ]]; then
  manifest="$(ls -1t "${ROOT}"/manifests/profiled-run-*.json 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "${manifest}" || ! -f "${manifest}" ]]; then
  die "profile manifest not found; pass a manifest path or run scripts/run-profiled-cells.sh"
fi

python3 - "${manifest}" <<'PY'
import json
import sys
from pathlib import Path

top_path = Path(sys.argv[1])
errors = []

def require_file(path, label, non_empty=True):
    if not path:
        errors.append(f"{label}: missing path")
        return
    p = Path(path)
    if not p.exists():
        errors.append(f"{label}: file does not exist: {p}")
        return
    if non_empty and p.stat().st_size == 0:
        errors.append(f"{label}: file is empty: {p}")

try:
    top = json.loads(top_path.read_text(encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"invalid top-level profile manifest JSON: {top_path}: {exc}")

if top.get("schema") != "more-go-java-go.profiled-run.v1":
    errors.append(f"unexpected top-level schema: {top.get('schema')}")

cell_manifests = top.get("cellManifests")
if not isinstance(cell_manifests, list) or not cell_manifests:
    errors.append("top-level manifest has no cellManifests")
    cell_manifests = []

for cell_manifest_path in cell_manifests:
    p = Path(cell_manifest_path)
    if not p.exists():
        errors.append(f"cell manifest missing: {p}")
        continue

    try:
        cell = json.loads(p.read_text(encoding="utf-8"))
    except Exception as exc:
        errors.append(f"invalid cell manifest JSON: {p}: {exc}")
        continue

    service = cell.get("service", "")
    load = cell.get("load", {})
    require_file(load.get("jsonl"), f"{p}: load jsonl")
    require_file(load.get("summary"), f"{p}: load summary")

    process = cell.get("processTelemetry", {})
    require_file(process.get("jsonl"), f"{p}: process telemetry", non_empty=False)

    if service == "java-helidon":
        java = cell.get("java", {})
        require_file(java.get("gcLog", {}).get("path"), f"{p}: Java GC log")
        require_file(java.get("jfr", {}).get("path"), f"{p}: Java JFR")
    elif service == "go-http":
        go = cell.get("go", {})
        pprof_required = bool(go.get("pprofRequired"))
        cpu = go.get("cpuProfile", {})
        heap = go.get("heapProfile", {})
        before = go.get("runtimeMetricsBefore", {})
        after = go.get("runtimeMetricsAfter", {})

        if cpu.get("path"):
            require_file(cpu.get("path"), f"{p}: Go CPU profile")
        elif pprof_required:
            errors.append(f"{p}: Go CPU profile required but not captured")

        if heap.get("path"):
            require_file(heap.get("path"), f"{p}: Go heap profile")
        elif pprof_required:
            errors.append(f"{p}: Go heap profile required but not captured")

        if before.get("path"):
            require_file(before.get("path"), f"{p}: Go runtime metrics before")
        if after.get("path"):
            require_file(after.get("path"), f"{p}: Go runtime metrics after")
    else:
        errors.append(f"{p}: unsupported service in manifest: {service}")

if errors:
    for error in errors:
        print(f"ERROR: {error}", file=sys.stderr)
    raise SystemExit(1)

print(f"profile_artifacts_valid={top_path}")
PY
