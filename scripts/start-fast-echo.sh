#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${ROOT}/scripts/common.sh"

SERVICE_NAME="fast-echo"
BIN="${BIN_DIR}/${SERVICE_NAME}"
PID_FILE="${PID_DIR}/${SERVICE_NAME}.pid"
LOG_FILE="${LOG_DIR}/${SERVICE_NAME}.log"
PORT="${FAST_ECHO_PORT:-18083}"
PORT="${PORT#:}"
HEALTH_URL="http://127.0.0.1:${PORT}/health"

mkdir -p "${BIN_DIR}" "${PID_DIR}" "${LOG_DIR}"

if [[ ! -x "${BIN}" ]]; then
  "${ROOT}/scripts/build-fast-echo.sh" >/dev/null
fi

[[ -x "${BIN}" ]] || die "fast-echo binary not found or not executable: ${BIN}"

stop_pid_file "${PID_FILE}"

health_exact() {
  local body
  body="$(curl -fsS "${HEALTH_URL}" 2>/dev/null || true)"
  [[ "${body}" == '{"status":"ok"}' ]]
}

FAST_ECHO_PORT="${PORT}" "${BIN}" >"${LOG_FILE}" 2>&1 &
pid="$!"
echo "${pid}" >"${PID_FILE}"

for _ in {1..120}; do
  if health_exact; then
    log "fast_echo_service_port=${PORT} pid=${pid}"
    exit 0
  fi

  if ! kill -0 "${pid}" >/dev/null 2>&1; then
    rm -f "${PID_FILE}"
    die "fast-echo exited before becoming healthy; see ${LOG_FILE}"
  fi

  sleep 0.25
done

kill "${pid}" >/dev/null 2>&1 || true
rm -f "${PID_FILE}"
die "fast-echo did not become ready at ${HEALTH_URL}; see ${LOG_FILE}"
