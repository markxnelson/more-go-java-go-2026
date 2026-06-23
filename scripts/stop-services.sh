#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${ROOT}/scripts/common.sh"

stop_pid_file "${PID_DIR}/go-http.pid"
stop_pid_file "${PID_DIR}/java-helidon.pid"
stop_pid_file "${PID_DIR}/fast-echo.pid"

log "stop-services: pass"
