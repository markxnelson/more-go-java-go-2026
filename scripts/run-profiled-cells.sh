#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

duration_seconds() {
  python3 - "$1" <<'PY'
import re
import sys

value = sys.argv[1].strip()
match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?)(ns|us|µs|ms|s|m|h)?", value)
if not match:
    raise SystemExit(f"invalid duration: {value}")
amount = float(match.group(1))
unit = match.group(2) or "s"
scale = {
    "ns": 1e-9,
    "us": 1e-6,
    "µs": 1e-6,
    "ms": 1e-3,
    "s": 1.0,
    "m": 60.0,
    "h": 3600.0,
}[unit]
seconds = amount * scale
print(max(1, int(round(seconds))))
PY
}

json_string_array_from_words() {
  python3 - "$@" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1:]))
PY
}

need_cmd python3
need_cmd curl

RUN_ID="${PROFILE_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
PROFILE_SERVICES="${PROFILE_SERVICES:-go java}"
PROFILE_REPEATS="${PROFILE_REPEATS:-1}"
PROFILE_DURATION="${PROFILE_DURATION:-30s}"
PROFILE_WARMUP="${PROFILE_WARMUP:-5s}"
PROFILE_CONCURRENCY="${PROFILE_CONCURRENCY:-4}"
PROFILE_CELL="${PROFILE_CELL:-profiled}"
PROFILE_FIXTURE="${PROFILE_FIXTURE:-${ROOT}/fixtures/valid/work-small.json}"
PROFILE_RATE="${PROFILE_RATE:-}"
PROFILE_RATE_SELECTION_MANIFEST="${PROFILE_RATE_SELECTION_MANIFEST:-}"
REQUIRE_GO_PPROF="${REQUIRE_GO_PPROF:-0}"
JAVA_PROFILE_SETTINGS="${JAVA_PROFILE_SETTINGS:-profile}"

PROFILE_DIR="${ROOT}/artifacts/profiles/${RUN_ID}"
RAW_PROFILE_DIR="${ROOT}/artifacts/raw/profiled/${RUN_ID}"
MANIFEST_DIR="${ROOT}/manifests"
TOP_MANIFEST="${MANIFEST_DIR}/profiled-run-${RUN_ID}.json"

mkdir -p "${PROFILE_DIR}" "${RAW_PROFILE_DIR}" "${MANIFEST_DIR}" "${TMP_DIR}"

if [[ ! -f "${PROFILE_FIXTURE}" ]]; then
  die "profile fixture not found: ${PROFILE_FIXTURE}"
fi

if [[ -z "${PROFILE_RATE}" ]]; then
  if [[ -n "${PROFILE_RATE_SELECTION_MANIFEST}" && -f "${PROFILE_RATE_SELECTION_MANIFEST}" ]]; then
    PROFILE_RATE="$(python3 - "${PROFILE_RATE_SELECTION_MANIFEST}" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
rate = data.get("selectedRate")
if rate is None:
    rate = data.get("selected", {}).get("rate")
if rate is None:
    raise SystemExit("selected rate not found")
print(rate)
PY
)"
  elif [[ -f "${ROOT}/artifacts/tmp/selected-rate.env" ]]; then
    PROFILE_RATE="$(sed -n 's/^SELECTED_RATE=//p' "${ROOT}/artifacts/tmp/selected-rate.env" | tail -n 1)"
  fi
fi

if [[ -z "${PROFILE_RATE}" ]]; then
  PROFILE_RATE="0"
fi

case "${PROFILE_RATE}" in
  ''|*[!0-9.]*)
    die "PROFILE_RATE must be numeric or empty; got: ${PROFILE_RATE}"
    ;;
esac

"${ROOT}/scripts/build-loadgen.sh" >/dev/null

cell_manifest_list="${TMP_DIR}/profiled-cell-manifests-${RUN_ID}.txt"
: > "${cell_manifest_list}"

cleanup() {
  "${ROOT}/scripts/stop-services.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_benchctl() {
  local url="$1"
  local service="$2"
  local variant="$3"
  local cell="$4"
  local repeat="$5"
  local jsonl="$6"
  local summary="$7"

  local args=(
    "${BIN_DIR}/benchctl"
    -url "${url}"
    -fixture "${PROFILE_FIXTURE}"
    -out "${jsonl}"
    -duration "${PROFILE_DURATION}"
    -concurrency "${PROFILE_CONCURRENCY}"
    -warmup "${PROFILE_WARMUP}"
    -service "${service}"
    -variant "${variant}"
    -cell "${cell}"
    -repeat "${repeat}"
    -summary-out "${summary}"
  )

  if [[ "${PROFILE_RATE}" != "0" && "${PROFILE_RATE}" != "0.0" ]]; then
    args+=(-rate "${PROFILE_RATE}")
  fi

  "${args[@]}"
}

record_cell_manifest() {
  local path="$1"
  echo "${path}" >> "${cell_manifest_list}"
}

for service in ${PROFILE_SERVICES}; do
  for repeat in $(seq 1 "${PROFILE_REPEATS}"); do
    cell="${PROFILE_CELL}-${service}-r${repeat}"
    service_dir="${PROFILE_DIR}/${cell}"
    raw_dir="${RAW_PROFILE_DIR}/${cell}"
    mkdir -p "${service_dir}" "${raw_dir}"

    jsonl="${raw_dir}/loadgen.jsonl"
    summary="${raw_dir}/summary.json"
    process_jsonl="${service_dir}/process.jsonl"
    cell_manifest="${service_dir}/manifest.json"

    if [[ "${service}" == "go" || "${service}" == "go-http" ]]; then
      service_name="go-http"
      variant="${GO_PROFILE_VARIANT:-go-http}"
      url="http://127.0.0.1:${GO_PORT}/work"
      cpu_profile="${service_dir}/go-cpu.pprof"
      heap_profile="${service_dir}/go-heap.pprof"
      metrics_before="${service_dir}/go-runtime-before.json"
      metrics_after="${service_dir}/go-runtime-after.json"
      pprof_base="${GO_PPROF_BASE_URL:-http://127.0.0.1:${GO_PORT}/debug/pprof}"
      metrics_url="${GO_RUNTIME_METRICS_URL:-http://127.0.0.1:${GO_PORT}/debug/vars}"

      cleanup
      "${ROOT}/scripts/start-go.sh" >/dev/null
      pid="$(cat "${PID_DIR}/go-http.pid")"

      "${ROOT}/scripts/sample-process.sh" -pid "${pid}" -out "${process_jsonl}" -interval "${PROCESS_SAMPLE_INTERVAL:-1}" > "${service_dir}/sample-process.log" 2>&1 &
      sampler_pid="$!"

      metrics_before_status="unavailable"
      if curl -fsS "${metrics_url}" -o "${metrics_before}" >/dev/null 2>&1; then
        metrics_before_status="captured"
      else
        rm -f "${metrics_before}"
      fi

      cpu_status="unavailable"
      profile_seconds="$(duration_seconds "${PROFILE_DURATION}")"
      if curl -fsS "${pprof_base}/profile?seconds=${profile_seconds}" -o "${cpu_profile}" > "${service_dir}/go-cpu-profile.log" 2>&1 &
      then
        pprof_pid="$!"
      else
        pprof_pid=""
      fi

      run_benchctl "${url}" "${service_name}" "${variant}" "${cell}" "${repeat}" "${jsonl}" "${summary}"

      if [[ -n "${pprof_pid:-}" ]]; then
        if wait "${pprof_pid}" >/dev/null 2>&1 && [[ -s "${cpu_profile}" ]]; then
          cpu_status="captured"
        else
          rm -f "${cpu_profile}"
        fi
      fi

      heap_status="unavailable"
      if curl -fsS "${pprof_base}/heap" -o "${heap_profile}" > "${service_dir}/go-heap-profile.log" 2>&1 && [[ -s "${heap_profile}" ]]; then
        heap_status="captured"
      else
        rm -f "${heap_profile}"
      fi

      metrics_after_status="unavailable"
      if curl -fsS "${metrics_url}" -o "${metrics_after}" >/dev/null 2>&1; then
        metrics_after_status="captured"
      else
        rm -f "${metrics_after}"
      fi

      kill "${sampler_pid}" >/dev/null 2>&1 || true
      wait "${sampler_pid}" >/dev/null 2>&1 || true
      cleanup

      SERVICE_NAME="${service_name}" \
      VARIANT="${variant}" \
      CELL="${cell}" \
      REPEAT="${repeat}" \
      RUN_ID="${RUN_ID}" \
      PROFILE_RATE="${PROFILE_RATE}" \
      PROFILE_DURATION="${PROFILE_DURATION}" \
      PROFILE_WARMUP="${PROFILE_WARMUP}" \
      PROFILE_CONCURRENCY="${PROFILE_CONCURRENCY}" \
      PROFILE_FIXTURE="${PROFILE_FIXTURE}" \
      JSONL="${jsonl}" \
      SUMMARY="${summary}" \
      PROCESS_JSONL="${process_jsonl}" \
      CPU_PROFILE="${cpu_profile}" \
      CPU_STATUS="${cpu_status}" \
      HEAP_PROFILE="${heap_profile}" \
      HEAP_STATUS="${heap_status}" \
      METRICS_BEFORE="${metrics_before}" \
      METRICS_BEFORE_STATUS="${metrics_before_status}" \
      METRICS_AFTER="${metrics_after}" \
      METRICS_AFTER_STATUS="${metrics_after_status}" \
      GO_PPROF_REQUIRED="${REQUIRE_GO_PPROF}" \
      PPROF_BASE="${pprof_base}" \
      CELL_MANIFEST="${cell_manifest}" \
      python3 - <<'PY'
import json
import os
from pathlib import Path

def existing_or_none(path):
    p = Path(path)
    return str(p) if p.exists() else None

manifest = {
    "schema": "more-go-java-go.profiled-cell.v1",
    "createdUtc": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runId": os.environ["RUN_ID"],
    "service": os.environ["SERVICE_NAME"],
    "variant": os.environ["VARIANT"],
    "cell": os.environ["CELL"],
    "repeat": int(os.environ["REPEAT"]),
    "load": {
        "rate": float(os.environ["PROFILE_RATE"]),
        "duration": os.environ["PROFILE_DURATION"],
        "warmup": os.environ["PROFILE_WARMUP"],
        "concurrency": int(os.environ["PROFILE_CONCURRENCY"]),
        "fixture": os.environ["PROFILE_FIXTURE"],
        "jsonl": os.environ["JSONL"],
        "summary": os.environ["SUMMARY"],
    },
    "processTelemetry": {
        "jsonl": os.environ["PROCESS_JSONL"],
    },
    "go": {
        "pprofBaseUrl": os.environ["PPROF_BASE"],
        "pprofRequired": os.environ["GO_PPROF_REQUIRED"] in ("1", "true", "yes"),
        "cpuProfile": {
            "status": os.environ["CPU_STATUS"],
            "path": existing_or_none(os.environ["CPU_PROFILE"]),
        },
        "heapProfile": {
            "status": os.environ["HEAP_STATUS"],
            "path": existing_or_none(os.environ["HEAP_PROFILE"]),
        },
        "runtimeMetricsBefore": {
            "status": os.environ["METRICS_BEFORE_STATUS"],
            "path": existing_or_none(os.environ["METRICS_BEFORE"]),
        },
        "runtimeMetricsAfter": {
            "status": os.environ["METRICS_AFTER_STATUS"],
            "path": existing_or_none(os.environ["METRICS_AFTER"]),
        },
    },
}
Path(os.environ["CELL_MANIFEST"]).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY
      record_cell_manifest "${cell_manifest}"

    elif [[ "${service}" == "java" || "${service}" == "java-helidon" ]]; then
      service_name="java-helidon"
      variant="${JAVA_PROFILE_VARIANT:-${JAVA_VARIANT:-java-helidon}}"
      url="http://127.0.0.1:${JAVA_PORT}/work"
      gc_log="${service_dir}/java-gc.log"
      jfr_file="${service_dir}/java.jfr"
      java_command_env="${service_dir}/java-command.env"

      cleanup
      java_args="${JAVA_JVM_ARGS:-}"
      java_args="${java_args} -Xlog:gc*:file=${gc_log}:time,uptime,level,tags"
      java_args="${java_args} -XX:StartFlightRecording=filename=${jfr_file},settings=${JAVA_PROFILE_SETTINGS},dumponexit=true,disk=true"
      JAVA_JVM_ARGS="${java_args}" "${ROOT}/scripts/start-java.sh" >/dev/null
      pid="$(cat "${PID_DIR}/java-helidon.pid")"
      cp "${ROOT}/artifacts/logs/java-helidon.command.env" "${java_command_env}" 2>/dev/null || true

      "${ROOT}/scripts/sample-process.sh" -pid "${pid}" -out "${process_jsonl}" -interval "${PROCESS_SAMPLE_INTERVAL:-1}" > "${service_dir}/sample-process.log" 2>&1 &
      sampler_pid="$!"

      run_benchctl "${url}" "${service_name}" "${variant}" "${cell}" "${repeat}" "${jsonl}" "${summary}"

      cleanup
      kill "${sampler_pid}" >/dev/null 2>&1 || true
      wait "${sampler_pid}" >/dev/null 2>&1 || true

      SERVICE_NAME="${service_name}" \
      VARIANT="${variant}" \
      CELL="${cell}" \
      REPEAT="${repeat}" \
      RUN_ID="${RUN_ID}" \
      PROFILE_RATE="${PROFILE_RATE}" \
      PROFILE_DURATION="${PROFILE_DURATION}" \
      PROFILE_WARMUP="${PROFILE_WARMUP}" \
      PROFILE_CONCURRENCY="${PROFILE_CONCURRENCY}" \
      PROFILE_FIXTURE="${PROFILE_FIXTURE}" \
      JSONL="${jsonl}" \
      SUMMARY="${summary}" \
      PROCESS_JSONL="${process_jsonl}" \
      GC_LOG="${gc_log}" \
      JFR_FILE="${jfr_file}" \
      JAVA_COMMAND_ENV="${java_command_env}" \
      CELL_MANIFEST="${cell_manifest}" \
      python3 - <<'PY'
import json
import os
from pathlib import Path
from datetime import datetime, timezone

def status(path):
    p = Path(path)
    return "captured" if p.exists() and p.stat().st_size > 0 else "missing"

manifest = {
    "schema": "more-go-java-go.profiled-cell.v1",
    "createdUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runId": os.environ["RUN_ID"],
    "service": os.environ["SERVICE_NAME"],
    "variant": os.environ["VARIANT"],
    "cell": os.environ["CELL"],
    "repeat": int(os.environ["REPEAT"]),
    "load": {
        "rate": float(os.environ["PROFILE_RATE"]),
        "duration": os.environ["PROFILE_DURATION"],
        "warmup": os.environ["PROFILE_WARMUP"],
        "concurrency": int(os.environ["PROFILE_CONCURRENCY"]),
        "fixture": os.environ["PROFILE_FIXTURE"],
        "jsonl": os.environ["JSONL"],
        "summary": os.environ["SUMMARY"],
    },
    "processTelemetry": {
        "jsonl": os.environ["PROCESS_JSONL"],
    },
    "java": {
        "gcLog": {
            "status": status(os.environ["GC_LOG"]),
            "path": os.environ["GC_LOG"],
        },
        "jfr": {
            "status": status(os.environ["JFR_FILE"]),
            "path": os.environ["JFR_FILE"],
        },
        "commandEnv": os.environ["JAVA_COMMAND_ENV"] if Path(os.environ["JAVA_COMMAND_ENV"]).exists() else None,
    },
}
Path(os.environ["CELL_MANIFEST"]).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY
      record_cell_manifest "${cell_manifest}"
    else
      die "unsupported PROFILE_SERVICES entry: ${service}"
    fi
  done
done

cell_array="$(python3 - "${cell_manifest_list}" <<'PY'
import json
import sys
from pathlib import Path

items = [line.strip() for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]
print(json.dumps(items))
PY
)"

PROFILE_SERVICES_JSON="$(json_string_array_from_words ${PROFILE_SERVICES})" \
RUN_ID="${RUN_ID}" \
PROFILE_DIR="${PROFILE_DIR}" \
RAW_PROFILE_DIR="${RAW_PROFILE_DIR}" \
PROFILE_SERVICES_JSON="${PROFILE_SERVICES_JSON:-}" \
PROFILE_REPEATS="${PROFILE_REPEATS}" \
PROFILE_RATE="${PROFILE_RATE}" \
PROFILE_DURATION="${PROFILE_DURATION}" \
PROFILE_WARMUP="${PROFILE_WARMUP}" \
PROFILE_CONCURRENCY="${PROFILE_CONCURRENCY}" \
PROFILE_FIXTURE="${PROFILE_FIXTURE}" \
CELL_MANIFESTS="${cell_array}" \
TOP_MANIFEST="${TOP_MANIFEST}" \
python3 - <<'PY'
import json
import os
from pathlib import Path
from datetime import datetime, timezone

manifest = {
    "schema": "more-go-java-go.profiled-run.v1",
    "createdUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "runId": os.environ["RUN_ID"],
    "profileDir": os.environ["PROFILE_DIR"],
    "rawDir": os.environ["RAW_PROFILE_DIR"],
    "services": json.loads(os.environ["PROFILE_SERVICES_JSON"]),
    "repeats": int(os.environ["PROFILE_REPEATS"]),
    "load": {
        "rate": float(os.environ["PROFILE_RATE"]),
        "duration": os.environ["PROFILE_DURATION"],
        "warmup": os.environ["PROFILE_WARMUP"],
        "concurrency": int(os.environ["PROFILE_CONCURRENCY"]),
        "fixture": os.environ["PROFILE_FIXTURE"],
    },
    "cellManifests": json.loads(os.environ["CELL_MANIFESTS"]),
    "notes": [
        "Artifacts are captured from this run only.",
        "Missing Go pprof artifacts indicate that the configured pprof endpoint was unavailable, unless pprofRequired is true.",
        "No benchmark interpretation is performed by this manifest.",
    ],
}
Path(os.environ["TOP_MANIFEST"]).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY

"${ROOT}/scripts/validate-profile-artifacts.sh" "${TOP_MANIFEST}"

log "profiled_run_manifest=${TOP_MANIFEST}"
log "profiled_run_status=artifacts_written_no_measurement_fabrication"
