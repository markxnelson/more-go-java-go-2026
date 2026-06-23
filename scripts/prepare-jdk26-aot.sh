#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

JAVA_BINARY_INPUT="${1:-${JAVA_BINARY:-}}"
AOT_MANIFEST="${2:-${AOT_MANIFEST:-${ROOT}/artifacts/aot/jdk26-aot-manifest.json}}"
AOT_CACHE="${3:-${AOT_CACHE:-${ROOT}/artifacts/aot/jdk26-helidon-aot.cache}}"

if [[ -z "${JAVA_BINARY_INPUT}" ]]; then
  echo "ERROR: Java binary is required. Usage: $0 <java-binary> <output-manifest> [cache-path]" >&2
  exit 2
fi

if [[ "${JAVA_BINARY_INPUT}" != */* ]]; then
  if ! JAVA_BINARY_RESOLVED="$(command -v "${JAVA_BINARY_INPUT}")"; then
    echo "ERROR: Java binary '${JAVA_BINARY_INPUT}' was not found on PATH." >&2
    exit 2
  fi
else
  JAVA_BINARY_RESOLVED="${JAVA_BINARY_INPUT}"
fi

JAVA_BINARY="$(cd "$(dirname "${JAVA_BINARY_RESOLVED}")" && pwd)/$(basename "${JAVA_BINARY_RESOLVED}")"

if [[ ! -x "${JAVA_BINARY}" ]]; then
  echo "ERROR: Java binary is not executable: ${JAVA_BINARY}" >&2
  exit 2
fi

mkdir -p "$(dirname "${AOT_MANIFEST}")" "$(dirname "${AOT_CACHE}")"

find_helidon_jar() {
  if [[ -n "${HELIDON_JAR:-}" ]]; then
    if [[ -f "${HELIDON_JAR}" ]]; then
      printf '%s
' "${HELIDON_JAR}"
      return 0
    fi
    echo "ERROR: HELIDON_JAR is set but does not exist: ${HELIDON_JAR}" >&2
    return 1
  fi

  local -a jars=()
  while IFS= read -r jar; do
    jars+=("${jar}")
  done < <(
    find "${ROOT}" \
      \( -path "${ROOT}/.cache" -o -path "${ROOT}/artifacts/aot" \) -prune \
      -o -type f -name "*.jar" \
      ! -name "*-sources.jar" \
      ! -name "*-javadoc.jar" \
      ! -name "original-*.jar" \
      -print | sort
  )

  local -a preferred=()
  local jar
  for jar in "${jars[@]}"; do
    case "${jar}" in
      *helidon*|*/helidon*/target/*|*/target/*helidon*.jar)
        preferred+=("${jar}")
        ;;
    esac
  done

  if [[ "${#preferred[@]}" -eq 1 ]]; then
    printf '%s
' "${preferred[0]}"
    return 0
  fi

  if [[ "${#jars[@]}" -eq 1 ]]; then
    printf '%s
' "${jars[0]}"
    return 0
  fi

  echo "ERROR: Unable to choose the Helidon benchmark jar automatically." >&2
  echo "Set HELIDON_JAR to the runnable Helidon jar path, then retry." >&2
  if [[ "${#jars[@]}" -gt 0 ]]; then
    echo "Candidate jars:" >&2
    printf '  %s
' "${jars[@]}" >&2
  fi
  return 1
}

json_is_valid() {
  python3 - "$1" <<'PY'
import json
import sys
from pathlib import Path

try:
    json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
except Exception:
    sys.exit(1)
PY
}

fixture_is_errorish() {
  local path="$1"
  case "${path}" in
    */fixtures/error/*|*/fixtures/errors/*|*/fixtures/invalid/*|fixtures/error/*|fixtures/errors/*|fixtures/invalid/*)
      return 0
      ;;
  esac
  return 1
}

trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s
' "${value}"
}

fixture_candidate_from_name() {
  local name="$1"
  local base="${name##*/}"
  local stem="${base%.json}"
  local candidate
  local -a candidates=(
    "${ROOT}/fixtures/valid/${stem}.json"
    "${ROOT}/fixtures/valid/${base}"
    "${ROOT}/fixtures/valid/${name}"
    "${ROOT}/fixtures/valid/${name}.json"
    "${ROOT}/fixtures/work/valid/${stem}.json"
    "${ROOT}/fixtures/work/valid/${base}"
    "${name}"
    "${ROOT}/${name}"
    "${ROOT}/fixtures/${name}"
    "${ROOT}/fixtures/${name}.json"
    "${ROOT}/fixtures/work/${name}"
    "${ROOT}/fixtures/work/${name}.json"
    "${ROOT}/fixtures/error/${name}"
    "${ROOT}/fixtures/error/${name}.json"
    "${ROOT}/fixtures/errors/${name}"
    "${ROOT}/fixtures/errors/${name}.json"
    "${ROOT}/fixtures/invalid/${name}"
    "${ROOT}/fixtures/invalid/${name}.json"
  )

  for candidate in "${candidates[@]}"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s
' "${candidate}"
      return 0
    fi
  done

  return 1
}

find_valid_fixture_dir_fixture() {
  local fixture

  if [[ -d "${ROOT}/fixtures/valid" ]]; then
    while IFS= read -r fixture; do
      if json_is_valid "${fixture}"; then
        printf '%s
' "${fixture}"
        return 0
      fi
    done < <(
      find "${ROOT}/fixtures/valid" -maxdepth 1 -type f -name "*.json" -print 2>/dev/null | sort
    )

    while IFS= read -r fixture; do
      if json_is_valid "${fixture}"; then
        printf '%s
' "${fixture}"
        return 0
      fi
    done < <(
      find "${ROOT}/fixtures/valid" -mindepth 2 -type f -name "*.json" -print 2>/dev/null | sort
    )
  fi

  if [[ -d "${ROOT}/fixtures" ]]; then
    while IFS= read -r fixture; do
      if json_is_valid "${fixture}"; then
        printf '%s
' "${fixture}"
        return 0
      fi
    done < <(
      find "${ROOT}/fixtures" -type f -path "*/valid/*.json" ! -path "${ROOT}/fixtures/valid/*" -print 2>/dev/null | sort
    )
  fi

  return 1
}

find_work_fixture() {
  if [[ -n "${WORK_FIXTURE:-}" ]]; then
    if [[ -f "${WORK_FIXTURE}" ]] && json_is_valid "${WORK_FIXTURE}"; then
      printf '%s
' "${WORK_FIXTURE}"
      return 0
    fi
    echo "ERROR: WORK_FIXTURE is set but is not an existing valid JSON file: ${WORK_FIXTURE}" >&2
    return 1
  fi

  local fixture_list_candidate=""
  local fixture_list_candidate_valid="false"
  local fixture_list_candidate_errorish="false"

  if [[ -n "${FIXTURE_LIST:-}" ]]; then
    local first_fixture="${FIXTURE_LIST%%,*}"
    first_fixture="$(trim_value "${first_fixture}")"

    if [[ -n "${first_fixture}" ]]; then
      local candidate
      if candidate="$(fixture_candidate_from_name "${first_fixture}")" && json_is_valid "${candidate}"; then
        fixture_list_candidate="${candidate}"
        fixture_list_candidate_valid="true"

        if fixture_is_errorish "${candidate}"; then
          fixture_list_candidate_errorish="true"
        else
          printf '%s
' "${candidate}"
          return 0
        fi
      fi
    fi
  fi

  local fixture
  if fixture="$(find_valid_fixture_dir_fixture)"; then
    printf '%s
' "${fixture}"
    return 0
  fi

  if [[ -d "${ROOT}/fixtures" ]]; then
    while IFS= read -r fixture; do
      if json_is_valid "${fixture}"; then
        printf '%s
' "${fixture}"
        return 0
      fi
    done < <(
      find "${ROOT}/fixtures" -type f -name "*.json" \
        ! -path "*/fixtures/error/*" \
        ! -path "*/fixtures/errors/*" \
        ! -path "*/fixtures/invalid/*" \
        -print 2>/dev/null | sort
    )
  fi

  if [[ "${fixture_list_candidate_valid}" == "true" ]]; then
    printf '%s
' "${fixture_list_candidate}"
    return 0
  fi

  if [[ -d "${ROOT}/fixtures" ]]; then
    while IFS= read -r fixture; do
      if json_is_valid "${fixture}"; then
        printf '%s
' "${fixture}"
        return 0
      fi
    done < <(
      find "${ROOT}/fixtures" -type f -name "*.json" -print 2>/dev/null | sort
    )
  fi

  echo "ERROR: Unable to find an existing valid JSON fixture for /work." >&2
  echo "Set WORK_FIXTURE to a valid fixture file or set FIXTURE_LIST to a fixture name/path." >&2
  return 1
}

free_port() {
  python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

HELIDON_JAR="$(find_helidon_jar)"
WORK_FIXTURE="$(find_work_fixture)"
PORT="${AOT_RECORD_PORT:-$(free_port)}"
LOG_DIR="${ROOT}/artifacts/aot/logs"
LOG_FILE="${LOG_DIR}/$(basename "${AOT_CACHE}").record.log"
mkdir -p "${LOG_DIR}"

rm -f "${AOT_CACHE}" "${AOT_MANIFEST}"

cleanup_pid=""
cleanup() {
  if [[ -n "${cleanup_pid}" ]] && kill -0 "${cleanup_pid}" 2>/dev/null; then
    kill -TERM "${cleanup_pid}" 2>/dev/null || true
    wait "${cleanup_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

JAVA_PORT="${PORT}" \
BENCHMARK_TRAINING_SHUTDOWN=true \
"${JAVA_BINARY}" \
  -XX:AOTMode=record \
  "-XX:AOTCacheOutput=${AOT_CACHE}" \
  -jar "${HELIDON_JAR}" \
  >"${LOG_FILE}" 2>&1 &

cleanup_pid="$!"

health_url="http://127.0.0.1:${PORT}/health"
work_url="http://127.0.0.1:${PORT}/work"
shutdown_url="http://127.0.0.1:${PORT}/__benchmark/shutdown"

started="false"
for _ in $(seq 1 120); do
  if ! kill -0 "${cleanup_pid}" 2>/dev/null; then
    echo "ERROR: Helidon process exited before /health became ready. Log: ${LOG_FILE}" >&2
    tail -n 120 "${LOG_FILE}" >&2 || true
    exit 1
  fi

  if curl -fsS "${health_url}" >/dev/null; then
    started="true"
    break
  fi

  sleep 0.5
done

if [[ "${started}" != "true" ]]; then
  echo "ERROR: Timed out waiting for Helidon /health on ${health_url}. Log: ${LOG_FILE}" >&2
  tail -n 120 "${LOG_FILE}" >&2 || true
  exit 1
fi

if ! curl -fsS \
  -X POST \
  -H "Content-Type: application/json" \
  --data-binary @"${WORK_FIXTURE}" \
  "${work_url}" >/dev/null; then
  echo "ERROR: /work request failed on ${work_url} using fixture ${WORK_FIXTURE}. Log: ${LOG_FILE}" >&2
  tail -n 120 "${LOG_FILE}" >&2 || true
  exit 1
fi

shutdown_requested="false"
if curl -fsS -X POST "${shutdown_url}" >/dev/null; then
  shutdown_requested="true"
else
  echo "WARN: Graceful shutdown request failed on ${shutdown_url}; will fall back to SIGTERM if the process remains alive. Log: ${LOG_FILE}" >&2
fi

if [[ "${shutdown_requested}" == "true" ]]; then
  for _ in $(seq 1 60); do
    if ! kill -0 "${cleanup_pid}" 2>/dev/null; then
      wait "${cleanup_pid}" 2>/dev/null || true
      cleanup_pid=""
      break
    fi
    sleep 0.5
  done
fi

if [[ -n "${cleanup_pid}" ]] && kill -0 "${cleanup_pid}" 2>/dev/null; then
  echo "WARN: Helidon process did not stop after graceful shutdown request; sending SIGTERM. Log: ${LOG_FILE}" >&2
  kill -TERM "${cleanup_pid}" 2>/dev/null || true
  wait "${cleanup_pid}" 2>/dev/null || true
  cleanup_pid=""
fi

if [[ -n "${cleanup_pid}" ]]; then
  wait "${cleanup_pid}" 2>/dev/null || true
  cleanup_pid=""
fi

if [[ ! -s "${AOT_CACHE}" ]]; then
  echo "ERROR: AOT cache was not created or is empty: ${AOT_CACHE}" >&2
  echo "Record log: ${LOG_FILE}" >&2
  tail -n 120 "${LOG_FILE}" >&2 || true
  exit 1
fi

JAVA_VERSION_OUTPUT="$("${JAVA_BINARY}" -version 2>&1 | head -n 1 || true)"

python3 - "${AOT_MANIFEST}" "${JAVA_BINARY}" "${JAVA_VERSION_OUTPUT}" "${HELIDON_JAR}" "${WORK_FIXTURE}" "${AOT_CACHE}" "${LOG_FILE}" "${PORT}" <<'PY'
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
data = {
    "javaBinary": sys.argv[2],
    "javaVersionLine": sys.argv[3],
    "helidonJar": sys.argv[4],
    "workFixture": sys.argv[5],
    "aotCache": sys.argv[6],
    "recordLog": sys.argv[7],
    "recordPort": int(sys.argv[8]),
    "recordJvmArgs": [
        "-XX:AOTMode=record",
        f"-XX:AOTCacheOutput={sys.argv[6]}",
    ],
    "runJvmArgs": [
        "-XX:AOTMode=on",
        f"-XX:AOTCache={sys.argv[6]}",
    ],
}
manifest_path.write_text(json.dumps(data, indent=2) + chr(10), encoding="utf-8")
PY

echo "AOT cache recorded: ${AOT_CACHE}"
echo "AOT manifest written: ${AOT_MANIFEST}"
echo "Record log: ${LOG_FILE}"
