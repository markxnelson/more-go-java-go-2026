#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

RUN_ID="${RATE_SELECTION_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
TARGET_UTILIZATION="${TARGET_UTILIZATION:-0.70}"
MIN_SELECTED_RATE="${MIN_SELECTED_RATE:-1}"
HEADROOM_MANIFEST="${HEADROOM_MANIFEST:-}"

if [[ -z "${HEADROOM_MANIFEST}" ]]; then
  HEADROOM_MANIFEST="$(ls -1t "${ROOT}"/manifests/headroom-*.json 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "${HEADROOM_MANIFEST}" || ! -f "${HEADROOM_MANIFEST}" ]]; then
  log "no headroom manifest found; running scripts/run-loadgen-headroom.sh first"
  "${ROOT}/scripts/run-loadgen-headroom.sh"
  HEADROOM_MANIFEST="$(ls -1t "${ROOT}"/manifests/headroom-*.json 2>/dev/null | head -n 1 || true)"
fi

[[ -n "${HEADROOM_MANIFEST}" && -f "${HEADROOM_MANIFEST}" ]] || die "headroom manifest not available"

MANIFEST="${ROOT}/manifests/rate-selection-${RUN_ID}.json"
SELECTED_ENV="${ROOT}/artifacts/tmp/selected-rate.env"
mkdir -p "${ROOT}/manifests" "${ROOT}/artifacts/tmp"

RUN_ID="${RUN_ID}" \
HEADROOM_MANIFEST="${HEADROOM_MANIFEST}" \
TARGET_UTILIZATION="${TARGET_UTILIZATION}" \
MIN_SELECTED_RATE="${MIN_SELECTED_RATE}" \
MANIFEST="${MANIFEST}" \
SELECTED_ENV="${SELECTED_ENV}" \
python3 - <<'PY'
import json
import math
import os
from datetime import datetime, timezone
from pathlib import Path

headroom_path = Path(os.environ["HEADROOM_MANIFEST"])
headroom = json.loads(headroom_path.read_text(encoding="utf-8"))

target_utilization = float(os.environ["TARGET_UTILIZATION"])
if not (0 < target_utilization <= 1):
    raise SystemExit("TARGET_UTILIZATION must be > 0 and <= 1")

min_rate = float(os.environ["MIN_SELECTED_RATE"])
summaries = headroom.get("summaries", [])
if not summaries:
    raise SystemExit("headroom manifest has no summaries")

usable = [item for item in summaries if item.get("errors", 0) == 0 and item.get("throughputRequestsPerSecond", 0) > 0]
if not usable:
    usable = [item for item in summaries if item.get("throughputRequestsPerSecond", 0) > 0]

if not usable:
    raise SystemExit("no positive throughput observations found in headroom manifest")

best = max(usable, key=lambda item: item.get("throughputRequestsPerSecond", 0))
observed = float(best["throughputRequestsPerSecond"])
selected = max(min_rate, math.floor(observed * target_utilization))
if selected > observed:
    selected = max(1, math.floor(observed))

manifest = {
    "schema": "more-go-java-go.rate-selection.v1",
    "createdUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runId": os.environ["RUN_ID"],
    "headroomManifest": str(headroom_path),
    "service": headroom.get("service"),
    "variant": headroom.get("variant"),
    "targetUtilization": target_utilization,
    "minSelectedRate": min_rate,
    "bestObserved": best,
    "selectedRate": selected,
    "selected": {
        "rate": selected,
        "basis": "floor(bestObserved.throughputRequestsPerSecond * targetUtilization)",
    },
    "notes": [
        "The selected rate is derived from raw headroom output from this package.",
        "No performance measurement is fabricated by this script.",
    ],
}

Path(os.environ["MANIFEST"]).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
Path(os.environ["SELECTED_ENV"]).write_text(
    f"SELECTED_RATE={selected}\n"
    f"RATE_SELECTION_MANIFEST={os.environ['MANIFEST']}\n"
    f"HEADROOM_MANIFEST={headroom_path}\n",
    encoding="utf-8",
)
print(f"selected_rate={selected}")
PY

log "rate_selection_manifest=${MANIFEST}"
log "rate_selection_env=${SELECTED_ENV}"
