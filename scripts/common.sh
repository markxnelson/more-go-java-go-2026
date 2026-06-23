#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CACHE_DIR="${ROOT}/.cache"
BIN_DIR="${CACHE_DIR}/bin"
PID_DIR="${CACHE_DIR}/pids"

ARTIFACTS_DIR="${ROOT}/artifacts"
LOG_DIR="${ARTIFACTS_DIR}/logs"
RAW_DIR="${ARTIFACTS_DIR}/raw"
TMP_DIR="${ARTIFACTS_DIR}/tmp"
PROFILE_DIR="${ARTIFACTS_DIR}/profiles"
MANIFEST_DIR="${ROOT}/manifests"

GO_PORT="${GO_PORT:-18081}"
JAVA_PORT="${JAVA_PORT:-18082}"

export GOCACHE="${GOCACHE:-${CACHE_DIR}/go-build}"
export GOMODCACHE="${GOMODCACHE:-${CACHE_DIR}/go-mod}"

mkdir -p \
  "${BIN_DIR}" \
  "${PID_DIR}" \
  "${LOG_DIR}" \
  "${RAW_DIR}" \
  "${TMP_DIR}" \
  "${PROFILE_DIR}" \
  "${MANIFEST_DIR}" \
  "${GOCACHE}" \
  "${GOMODCACHE}"

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "missing required command: ${cmd}"
}

run_logged() {
  local name="$1"
  shift

  mkdir -p "${LOG_DIR}"

  {
    printf 'command:'
    printf ' %q' "$@"
    printf '\n'
    "$@"
  } 2>&1 | tee "${LOG_DIR}/${name}.log"
}

wait_for_http() {
  local url="$1"
  local attempts="${2:-80}"
  local sleep_seconds="${3:-0.25}"
  local i

  for ((i = 1; i <= attempts; i++)); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep "${sleep_seconds}"
  done

  return 1
}

stop_pid_file() {
  local file="$1"

  if [[ ! -f "${file}" ]]; then
    return 0
  fi

  local pid
  pid="$(cat "${file}" 2>/dev/null || true)"

  if [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1; then
    kill "${pid}" >/dev/null 2>&1 || true

    local i
    for ((i = 1; i <= 40; i++)); do
      if ! kill -0 "${pid}" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done

    if kill -0 "${pid}" >/dev/null 2>&1; then
      kill -9 "${pid}" >/dev/null 2>&1 || true
    fi

    wait "${pid}" >/dev/null 2>&1 || true
  fi

  rm -f "${file}"
}

version_env_value() {
  local key="$1"
  local file="${ROOT}/versions.env"

  if [[ ! -f "${file}" ]]; then
    printf 'unknown\n'
    return 0
  fi

  awk -F= -v key="${key}" '
    $1 == key {
      print substr($0, length(key) + 2)
      found = 1
      exit
    }
    END {
      if (!found) {
        print "unknown"
      }
    }
  ' "${file}"
}

json_escape_string() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}
