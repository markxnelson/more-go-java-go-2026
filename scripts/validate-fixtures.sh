#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

require_cmd jq

body_limit=4096
payload_max=131072

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

log "validate-fixtures: pass"
log "valid_fixture_count=${valid_count}"
log "error_fixture_count=${error_count}"
log "quoted_numeric_string_error_fixture_count=${quoted_numeric_string_count}"
log "body-too-large-bytes=${size}"
log "body_limit_bytes=${body_limit}"
log "payload_size_max=${payload_max}"
