#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${ROOT}/scripts/common.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/go-java-go-smoke-checks.XXXXXX")"

cleanup() {
  rm -rf "${TMP_DIR}"
  "${ROOT}/scripts/stop-services.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

expect_status() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  [[ "${actual}" == "${expected}" ]] || die "${label}: got HTTP ${actual}, expected ${expected}"
}

expect_rejected() {
  local label="$1"
  local status="$2"

  case "${status}" in
    400|413|415)
      ;;
    *)
      die "${label}: expected rejection status 400, 413, or 415; got ${status}"
      ;;
  esac
}

check_contract_for_service() {
  local name="$1"
  local port="$2"
  local base_url="http://127.0.0.1:${port}"
  local status
  local body

  body="$(curl -fsS "${base_url}/health")"
  [[ "${body}" == '{"status":"ok"}' ]] || die "${name}: GET /health body mismatch: ${body}"

  status="$(curl -sS -o /dev/null -w '%{http_code}' -I "${base_url}/health")"
  expect_status "${name}: HEAD /health" "200" "${status}"

  status="$(
    curl -sS \
      -o "${TMP_DIR}/${name}-valid.json" \
      -w '%{http_code}' \
      -H 'content-type: application/json' \
      --data-binary @"${ROOT}/fixtures/valid/work-small.json" \
      "${base_url}/work"
  )"
  expect_status "${name}: valid request" "200" "${status}"

  status="$(
    curl -sS \
      -o "${TMP_DIR}/${name}-invalid-content-type.json" \
      -w '%{http_code}' \
      -H 'content-type: text/plain' \
      --data-binary @"${ROOT}/fixtures/valid/work-small.json" \
      "${base_url}/work"
  )"
  expect_rejected "${name}: invalid content type" "${status}"

  if [[ -f "${ROOT}/fixtures/errors/invalid-json.json" ]]; then
    status="$(
      curl -sS \
        -o "${TMP_DIR}/${name}-invalid-json.json" \
        -w '%{http_code}' \
        -H 'content-type: application/json' \
        --data-binary @"${ROOT}/fixtures/errors/invalid-json.json" \
        "${base_url}/work"
    )"
    expect_status "${name}: invalid JSON" "400" "${status}"
  fi

  if [[ -f "${ROOT}/fixtures/errors/unknown-field.json" ]]; then
    status="$(
      curl -sS \
        -o "${TMP_DIR}/${name}-unknown-field.json" \
        -w '%{http_code}' \
        -H 'content-type: application/json' \
        --data-binary @"${ROOT}/fixtures/errors/unknown-field.json" \
        "${base_url}/work"
    )"
    expect_status "${name}: unknown field" "400" "${status}"
  fi

  if [[ -f "${ROOT}/fixtures/errors/duplicate-field.json" ]]; then
    status="$(
      curl -sS \
        -o "${TMP_DIR}/${name}-duplicate-field.json" \
        -w '%{http_code}' \
        -H 'content-type: application/json' \
        --data-binary @"${ROOT}/fixtures/errors/duplicate-field.json" \
        "${base_url}/work"
    )"
    expect_status "${name}: duplicate field" "400" "${status}"
  fi

  if [[ -f "${ROOT}/fixtures/errors/quoted-numeric-string.json" ]]; then
    status="$(
      curl -sS \
        -o "${TMP_DIR}/${name}-quoted-numeric-string.json" \
        -w '%{http_code}' \
        -H 'content-type: application/json' \
        --data-binary @"${ROOT}/fixtures/errors/quoted-numeric-string.json" \
        "${base_url}/work"
    )"
    expect_status "${name}: quoted numeric string" "400" "${status}"
  fi

  if [[ -f "${ROOT}/fixtures/errors/body-too-large.json" ]]; then
    status="$(
      curl -sS \
        -o "${TMP_DIR}/${name}-body-too-large.json" \
        -w '%{http_code}' \
        -H 'content-type: application/json' \
        --data-binary @"${ROOT}/fixtures/errors/body-too-large.json" \
        "${base_url}/work"
    )"
    expect_status "${name}: decoded body too large" "413" "${status}"
  fi
}

"${ROOT}/scripts/start-go.sh" >/dev/null
check_contract_for_service "go" "${GO_PORT}"
"${ROOT}/scripts/stop-services.sh" >/dev/null

"${ROOT}/scripts/start-java.sh" >/dev/null
check_contract_for_service "java" "${JAVA_PORT}"

log "run-smoke-checks: pass"
