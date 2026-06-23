#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

require_cmd rg

tmp_file="$(mktemp)"
trap 'rm -f "${tmp_file}"' EXIT

pat_one="/v1/"'score'
pat_two="Score"'Request'
pat_three="Score"'Response'
pat_four="score"'-request'
pat_five="score"'-success'
pat_six="com.sun.net."httpserver

scan_args=(
  --hidden
  --glob '!/.git/**'
  --glob '!/.cache/**'
  --glob '!/artifacts/**'
  --glob '!**/target/**'
  --glob '!**/node_modules/**'
  --glob '!**/*.class'
  --glob '!**/*.jar'
  --glob '!**/*.jfr'
  --glob '!**/*.hprof'
)

if rg "${scan_args[@]}" -n "${pat_one}|${pat_two}|${pat_three}|${pat_four}|${pat_five}|${pat_six}" "${ROOT}" >"${tmp_file}" 2>/dev/null; then
  cat "${tmp_file}" >&2
  die "drift scan found forbidden legacy or disallowed Java HTTP-server text"
fi

if [[ -d "${ROOT}/services/go" ]]; then
  die "stale services/go directory exists; expected services/go-http"
fi

if [[ -d "${ROOT}/.agents/skills" ]]; then
  while IFS= read -r child; do
    if [[ "$(basename "${child}")" != "db" ]]; then
      die "disallowed .agents/skills child exists: ${child}"
    fi
  done < <(find "${ROOT}/.agents/skills" -mindepth 1 -maxdepth 1 -type d | sort)
fi

log "drift-scan: pass"
