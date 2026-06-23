#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${ROOT}/scripts/common.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/go-java-go-smoke.XXXXXX")"

cleanup() {
  rm -rf "${TMP_DIR}"
  "${ROOT}/scripts/stop-services.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

check_service() {
  local name="$1"
  local port="$2"
  local base_url="http://127.0.0.1:${port}"
  local body
  local status

  body="$(curl -fsS "${base_url}/health")"
  [[ "${body}" == '{"status":"ok"}' ]] || die "${name} GET /health body mismatch: ${body}"

  status="$(curl -sS -o "${TMP_DIR}/${name}-head-health.body" -w '%{http_code}' -I "${base_url}/health")"
  [[ "${status}" == "200" ]] || die "${name} HEAD /health status ${status}"

  if [[ -s "${TMP_DIR}/${name}-head-health.body" ]]; then
    :
  fi

  status="$(
    curl -sS \
      -o "${TMP_DIR}/${name}-work-valid.json" \
      -w '%{http_code}' \
      -H 'content-type: application/json' \
      --data-binary @"${ROOT}/fixtures/valid/work-small.json" \
      "${base_url}/work"
  )"
  [[ "${status}" == "200" ]] || die "${name} POST /work valid status ${status}"

  python3 -m json.tool "${TMP_DIR}/${name}-work-valid.json" >/dev/null \
    || die "${name} POST /work did not return valid JSON"
}

"${ROOT}/scripts/start-go.sh" >/dev/null
check_service "go" "${GO_PORT}"
"${ROOT}/scripts/stop-services.sh" >/dev/null

"${ROOT}/scripts/start-java.sh" >/dev/null
check_service "java" "${JAVA_PORT}"

log "run-smoke: pass"
