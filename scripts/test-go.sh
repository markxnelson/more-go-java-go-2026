#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

require_cmd go

(
  cd "${ROOT}/services/go-http"
  go test ./...
)

log "test-go: pass"
