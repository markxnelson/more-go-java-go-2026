#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${ROOT}/scripts/common.sh"

"${ROOT}/scripts/build-loadgen.sh" >/dev/null

cleanup() {
  "${ROOT}/scripts/stop-services.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "${RAW_DIR}"

"${ROOT}/scripts/start-go.sh" >/dev/null
"${BIN_DIR}/benchctl" \
  -url "http://127.0.0.1:${GO_PORT}/work" \
  -fixture "${ROOT}/fixtures/valid/work-small.json" \
  -out "${RAW_DIR}/go-http-small.jsonl" \
  -duration 2s \
  -concurrency 1 \
  -service go \
  -variant go-http \
  -cell smoke-small \
  -repeat 1
cleanup

"${ROOT}/scripts/start-java.sh" >/dev/null
"${BIN_DIR}/benchctl" \
  -url "http://127.0.0.1:${JAVA_PORT}/work" \
  -fixture "${ROOT}/fixtures/valid/work-small.json" \
  -out "${RAW_DIR}/java-helidon-small.jsonl" \
  -duration 2s \
  -concurrency 1 \
  -service java \
  -variant java-helidon \
  -cell smoke-small \
  -repeat 1

log "small_matrix_raw_artifacts=${RAW_DIR}"
log "small_matrix_status=raw_artifacts_written_no_interpretation"
