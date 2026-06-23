#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${ROOT}/scripts/common.sh"

SERVICE_NAME="go-http"
PID_FILE="${PID_DIR}/${SERVICE_NAME}.pid"
LOG_FILE="${LOG_DIR}/${SERVICE_NAME}.log"
HEALTH_URL="http://127.0.0.1:${GO_PORT}/health"

mkdir -p "${PID_DIR}" "${LOG_DIR}" "${BIN_DIR}"

"${ROOT}/scripts/build-go.sh" >/dev/null

if [[ ! -x "${BIN_DIR}/go-http" ]]; then
  die "Go service binary not found or not executable: ${BIN_DIR}/go-http"
fi

stop_pid_file "${PID_FILE}"

health_exact() {
  local body
  body="$(curl -fsS "${HEALTH_URL}" 2>/dev/null || true)"
  [[ "${body}" == '{"status":"ok"}' ]]
}

GO_ENV=(
  "GO_PORT=${GO_PORT}"
)

if [[ -n "${GOMAXPROCS:-}" ]]; then
  GO_ENV+=("GOMAXPROCS=${GOMAXPROCS}")
fi

if [[ -n "${GODEBUG:-}" ]]; then
  GO_ENV+=("GODEBUG=${GODEBUG}")
fi

env "${GO_ENV[@]}" "${BIN_DIR}/go-http" >"${LOG_FILE}" 2>&1 &
pid="$!"
echo "${pid}" >"${PID_FILE}"

for _ in {1..120}; do
  if health_exact; then
    log "go_service_port=${GO_PORT} pid=${pid}"
    exit 0
  fi

  if ! kill -0 "${pid}" >/dev/null 2>&1; then
    rm -f "${PID_FILE}"
    die "Go service exited before becoming healthy; see ${LOG_FILE}"
  fi

  sleep 0.25
done

kill "${pid}" >/dev/null 2>&1 || true
rm -f "${PID_FILE}"
die "Go service did not become ready at ${HEALTH_URL}; see ${LOG_FILE}"
