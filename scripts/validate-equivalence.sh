#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/common.sh
source "${ROOT}/scripts/common.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/go-java-go-equivalence.XXXXXX")"

cleanup() {
  rm -rf "${TMP_DIR}"
  "${ROOT}/scripts/stop-services.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

canonical_json() {
  local input="$1"
  local output="$2"

  python3 - "$input" "$output" <<'PY'
import json
import sys

with open(sys.argv[1], "rb") as f:
    data = json.load(f)

with open(sys.argv[2], "w", encoding="utf-8") as f:
    json.dump(data, f, sort_keys=True, separators=(",", ":"))
    f.write(chr(10))
PY
}

post_work() {
  local url="$1"
  local fixture="$2"
  local output="$3"

  curl -sS \
    -o "${output}" \
    -w '%{http_code}' \
    -H 'content-type: application/json' \
    --data-binary @"${fixture}" \
    "${url}"
}

check_valid_fixture() {
  local fixture="$1"
  local name
  local go_status
  local java_status
  local go_body
  local java_body
  local go_canonical
  local java_canonical

  name="$(basename "${fixture}")"
  go_body="${TMP_DIR}/go-${name}"
  java_body="${TMP_DIR}/java-${name}"
  go_canonical="${TMP_DIR}/go-${name}.canonical"
  java_canonical="${TMP_DIR}/java-${name}.canonical"

  go_status="$(post_work "http://127.0.0.1:${GO_PORT}/work" "${fixture}" "${go_body}")"
  java_status="$(post_work "http://127.0.0.1:${JAVA_PORT}/work" "${fixture}" "${java_body}")"

  [[ "${go_status}" == "${java_status}" ]] \
    || die "status mismatch for ${name}: go=${go_status} java=${java_status}"
  [[ "${go_status}" == "200" ]] \
    || die "valid fixture ${name} returned unexpected status ${go_status}"

  canonical_json "${go_body}" "${go_canonical}"
  canonical_json "${java_body}" "${java_canonical}"

  cmp -s "${go_canonical}" "${java_canonical}" \
    || die "response body mismatch for valid fixture ${name}"

  log "${name} go=${go_status} java=${java_status} body=equivalent"
}

expected_error_status() {
  local fixture="$1"
  local name
  name="$(basename "${fixture}")"

  case "${name}" in
    body-too-large.json)
      printf '413'
      ;;
    *)
      printf '400'
      ;;
  esac
}

check_error_fixture() {
  local fixture="$1"
  local name
  local expected
  local go_status
  local java_status

  name="$(basename "${fixture}")"
  expected="$(expected_error_status "${fixture}")"

  go_status="$(post_work "http://127.0.0.1:${GO_PORT}/work" "${fixture}" "${TMP_DIR}/go-error-${name}")"
  java_status="$(post_work "http://127.0.0.1:${JAVA_PORT}/work" "${fixture}" "${TMP_DIR}/java-error-${name}")"

  [[ "${go_status}" == "${java_status}" ]] \
    || die "status mismatch for ${name}: go=${go_status} java=${java_status}"
  [[ "${go_status}" == "${expected}" ]] \
    || die "unexpected status for ${name}: got ${go_status}, expected ${expected}"

  log "${name} go=${go_status} java=${java_status}"
}

"${ROOT}/scripts/start-go.sh" >/dev/null
"${ROOT}/scripts/start-java.sh" >/dev/null

shopt -s nullglob

valid_fixtures=("${ROOT}"/fixtures/valid/*.json)
error_fixtures=("${ROOT}"/fixtures/errors/*.json)

(( ${#valid_fixtures[@]} > 0 )) || die "no valid fixtures found"
(( ${#error_fixtures[@]} > 0 )) || die "no error fixtures found"

for fixture in "${valid_fixtures[@]}"; do
  check_valid_fixture "${fixture}"
done

for fixture in "${error_fixtures[@]}"; do
  check_error_fixture "${fixture}"
done

log "equivalence_status=passed"
