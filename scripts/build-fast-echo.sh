#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

require_cmd go

mkdir -p "${BIN_DIR}"

(
  cd "${ROOT}/tools/fast-echo"
  go build -trimpath -o "${BIN_DIR}/fast-echo" ./cmd/fast-echo
)

log "build-fast-echo: pass"
log "binary=${BIN_DIR}/fast-echo"
