#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

require_cmd go

mkdir -p "${BIN_DIR}"

(
  cd "${ROOT}/services/go-http"
  go build -trimpath -o "${BIN_DIR}/go-http" ./cmd/go-http
)

log "build-go: pass"
log "binary=${BIN_DIR}/go-http"
