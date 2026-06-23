#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

require_cmd go

(
  cd "${ROOT}/tools/benchctl"
  go test ./...
)

log "test-loadgen: pass"
