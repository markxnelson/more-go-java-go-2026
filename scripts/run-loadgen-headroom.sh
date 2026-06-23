#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

RUN_ID="${HEADROOM_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
HEADROOM_SERVICE="${1:-${HEADROOM_SERVICE:-go}}"
HEADROOM_DURATION="${HEADROOM_DURATION:-10s}"
HEADROOM_WARMUP="${HEADROOM_WARMUP:-2s}"
HEADROOM_CONCURRENCY_LIST="${HEADROOM_CONCURRENCY_LIST:-1 2 4 8}"
HEADROOM_FIXTURE="${HEADROOM_FIXTURE:-${ROOT}/fixtures/valid/work-small.json}"
HEADROOM_CELL="${HEADROOM_CELL:-headroom}"

RAW_HEADROOM_DIR="${ROOT}/artifacts/raw/headroom/${RUN_ID}"
MANIFEST="${ROOT}/manifests/headroom-${RUN_ID}.json"
mkdir -p "${RAW_HEADROOM_DIR}" "${ROOT}/manifests"

[[ -f "${HEADROOM_FIXTURE}" ]] || die "headroom fixture not found: ${HEADROOM_FIXTURE}"

"${ROOT}/scripts/build-loadgen.sh" >/dev/null

cleanup() {
  "${ROOT}/scripts/stop-services.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

requested_service="${HEADROOM_SERVICE}"

case "${HEADROOM_SERVICE}" in
  go|go-http)
    service_name="go-http"
    variant="${GO_VARIANT:-go-http}"
    port="${GO_PORT}"
    "${ROOT}/scripts/start-go.sh" >/dev/null
    ;;
  java|java-helidon)
    service_name="java-helidon"
    variant="${JAVA_VARIANT:-java-helidon}"
    port="${JAVA_PORT}"
    "${ROOT}/scripts/start-java.sh" >/dev/null
    ;;
  fast|fast-echo)
    service_name="fast-echo"
    variant="${FAST_ECHO_VARIANT:-fast-echo}"
    port="${FAST_ECHO_PORT:-18083}"
    "${ROOT}/scripts/start-fast-echo.sh" >/dev/null
    ;;
  *)
    die "unsupported HEADROOM_SERVICE: ${HEADROOM_SERVICE}"
    ;;
esac

url="http://127.0.0.1:${port}/work"
summary_list="${RAW_HEADROOM_DIR}/summary-paths.txt"
: > "${summary_list}"

repeat=1
for concurrency in ${HEADROOM_CONCURRENCY_LIST}; do
  jsonl="${RAW_HEADROOM_DIR}/${service_name}-c${concurrency}.jsonl"
  summary="${RAW_HEADROOM_DIR}/${service_name}-c${concurrency}.summary.json"

  "${BIN_DIR}/benchctl" \
    -url "${url}" \
    -fixture "${HEADROOM_FIXTURE}" \
    -out "${jsonl}" \
    -duration "${HEADROOM_DURATION}" \
    -warmup "${HEADROOM_WARMUP}" \
    -concurrency "${concurrency}" \
    -service "${service_name}" \
    -variant "${variant}" \
    -cell "${HEADROOM_CELL}-c${concurrency}" \
    -repeat "${repeat}" \
    -summary-out "${summary}"

  printf '%s	%s	%s
' "${summary}" "${jsonl}" "${concurrency}" >> "${summary_list}"
done

RUN_ID="${RUN_ID}" \
REQUESTED_HEADROOM_SERVICE="${requested_service}" \
SERVICE_NAME="${service_name}" \
VARIANT="${variant}" \
URL="${url}" \
RAW_HEADROOM_DIR="${RAW_HEADROOM_DIR}" \
HEADROOM_DURATION="${HEADROOM_DURATION}" \
HEADROOM_WARMUP="${HEADROOM_WARMUP}" \
HEADROOM_FIXTURE="${HEADROOM_FIXTURE}" \
HEADROOM_CONCURRENCY_LIST="${HEADROOM_CONCURRENCY_LIST}" \
SUMMARY_LIST="${summary_list}" \
MANIFEST="${MANIFEST}" \
python3 - <<'PY'
import json
import os
from datetime import datetime, timezone
from pathlib import Path

def as_int(value, default=0):
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        try:
            return int(float(value))
        except (TypeError, ValueError):
            return default

summaries = []
for line in Path(os.environ["SUMMARY_LIST"]).read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue

    parts = line.split("	")
    path = Path(parts[0])
    fallback_output = parts[1] if len(parts) > 1 else None
    fallback_concurrency = as_int(parts[2], None) if len(parts) > 2 else None

    data = json.loads(path.read_text(encoding="utf-8"))

    duration_nanos = as_int(data.get("durationNanos"))
    warmup_duration_nanos = as_int(data.get("warmupDurationNanos"))
    measured_events = as_int(data.get("measuredEvents"))
    total_events = as_int(data.get("totalEvents"), measured_events)
    success_2xx = as_int(data.get("success2xx"))
    errors = as_int(data.get("errors"))
    concurrency = as_int(data.get("concurrency"), fallback_concurrency)
    throughput = (measured_events * 1_000_000_000 / duration_nanos) if duration_nanos > 0 else 0.0

    summaries.append({
        "service": data.get("service") or os.environ["SERVICE_NAME"],
        "variant": data.get("variant") or os.environ["VARIANT"],
        "concurrency": concurrency,
        "summaryOutput": str(path),
        "durationNanos": duration_nanos,
        "warmupDurationNanos": warmup_duration_nanos,
        "measuredEvents": measured_events,
        "totalEvents": total_events,
        "success2xx": success_2xx,
        "errors": errors,
        "output": data.get("output") or fallback_output,
        "throughputRequestsPerSecond": throughput,
    })

best = max(summaries, key=lambda item: item["throughputRequestsPerSecond"]) if summaries else None

manifest = {
    "schema": "more-go-java-go.headroom.v1",
    "createdUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runId": os.environ["RUN_ID"],
    "requestedService": os.environ["REQUESTED_HEADROOM_SERVICE"],
    "controlService": os.environ["SERVICE_NAME"],
    "service": os.environ["SERVICE_NAME"],
    "variant": os.environ["VARIANT"],
    "control": {
        "requestedService": os.environ["REQUESTED_HEADROOM_SERVICE"],
        "service": os.environ["SERVICE_NAME"],
        "variant": os.environ["VARIANT"],
        "url": os.environ["URL"],
    },
    "url": os.environ["URL"],
    "rawDir": os.environ["RAW_HEADROOM_DIR"],
    "fixture": os.environ["HEADROOM_FIXTURE"],
    "duration": os.environ["HEADROOM_DURATION"],
    "warmup": os.environ["HEADROOM_WARMUP"],
    "concurrencyList": [int(x) for x in os.environ["HEADROOM_CONCURRENCY_LIST"].split()],
    "summaries": summaries,
    "bestObserved": best,
    "notes": [
        "This is a local raw headroom run.",
        "The manifest records observed load-generator output only and does not interpret article results.",
        "controlService is normalized to one of fast-echo, go-http, or java-helidon.",
    ],
}
Path(os.environ["MANIFEST"]).write_text(json.dumps(manifest, indent=2) + chr(10), encoding="utf-8")
PY

log "headroom_manifest=${MANIFEST}"
log "headroom_status=raw_artifacts_written_no_interpretation"
