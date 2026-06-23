#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

require_cmd jq
require_cmd python3

contract="${ROOT}/contracts/work-contract.json"
[[ -f "${contract}" ]] || die "missing contract file: ${contract}"

body_limit="$(jq -r '.routes.work.bodyLimitBytes' "${contract}")"
payload_max="$(jq -r '.routes.work.fields.payloadSize.maximum' "${contract}")"

[[ "${body_limit}" == "4096" ]] || die "contract body limit must be 4096 bytes; got ${body_limit}"
[[ "${payload_max}" == "131072" ]] || die "payloadSize maximum must be 131072; got ${payload_max}"

valid_count=0
for file in "${ROOT}"/fixtures/valid/*.json; do
  [[ -e "${file}" ]] || die "no valid fixtures found"
  jq . "${file}" >/dev/null
  valid_count=$((valid_count + 1))
done

error_count=0
quoted_numeric_string_count=0
for file in "${ROOT}"/fixtures/errors/*.json; do
  [[ -e "${file}" ]] || die "no error fixtures found"

  if [[ "$(basename "${file}")" == "invalid-json.json" ]]; then
    if jq . "${file}" >/dev/null 2>&1; then
      die "invalid-json fixture unexpectedly parses: ${file}"
    fi
  else
    jq . "${file}" >/dev/null
  fi

  case "$(basename "${file}")" in
    payload-size-string.json|seed-string.json|extra-work-string.json)
      quoted_numeric_string_count=$((quoted_numeric_string_count + 1))
      ;;
  esac

  error_count=$((error_count + 1))
done

(( valid_count > 0 )) || die "expected at least one valid fixture"
(( error_count > 0 )) || die "expected at least one error fixture"
(( quoted_numeric_string_count > 0 )) || die "expected quoted numeric string error fixtures"

oversized_fixture="${ROOT}/fixtures/errors/body-too-large.json"
[[ -f "${oversized_fixture}" ]] || die "missing oversized body fixture: ${oversized_fixture}"

size="$(wc -c < "${oversized_fixture}" | tr -d ' ')"
if (( size <= body_limit )); then
  die "body-too-large fixture must be larger than ${body_limit} bytes; got ${size}"
fi

python3 - "${contract}" <<'PY'
import json
import sys
from pathlib import Path

contract = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))

health = contract["routes"]["health"]
work = contract["routes"]["work"]

assert set(health["methods"]) == {"GET", "HEAD"}
assert health["path"] == "/health"
assert health["getResponse"]["body"] == {"status": "ok"}

assert work["path"] == "/work"
assert work["contentType"] == "application/json"
assert work["bodyLimitBytes"] == 4096
assert work["required"] == ["requestId", "payloadSize", "seed", "extraWork"]

fields = work["fields"]
assert fields["requestId"]["type"] == "string"
assert fields["requestId"]["minLength"] == 1
assert fields["requestId"]["maxLength"] == 128
assert fields["payloadSize"]["type"] == "integer"
assert fields["payloadSize"]["minimum"] == 0
assert fields["payloadSize"]["maximum"] == 131072
assert fields["seed"]["type"] == "integer"
assert fields["seed"]["minimum"] == 0
assert fields["seed"]["maximum"] == 2147483647
assert fields["extraWork"]["type"] == "integer"
assert fields["extraWork"]["minimum"] == 0
assert fields["extraWork"]["maximum"] == 100

rules = set(work["strictRules"])
expected = {
    "reject unknown fields",
    "reject duplicate fields",
    "reject missing required fields",
    "reject scalar type violations",
    "reject quoted numeric strings",
    "reject numeric bound violations",
    "reject invalid json",
    "reject multiple json documents",
    "reject decoded bodies larger than 4096 bytes",
}
missing = sorted(expected - rules)
if missing:
    raise AssertionError(f"missing strict rules: {missing}")
PY

log "validate-fixtures: pass"
log "valid_fixture_count=${valid_count}"
log "error_fixture_count=${error_count}"
log "quoted_numeric_string_error_fixture_count=${quoted_numeric_string_count}"
log "body-too-large-bytes=${size}"
