#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

require_cmd go

mkdir -p "${BIN_DIR}"

(
  cd "${ROOT}/tools/benchctl"
  go build -trimpath -o "${BIN_DIR}/benchctl" ./cmd/benchctl
)

log "build-loadgen: pass"
log "binary=${BIN_DIR}/benchctl"
