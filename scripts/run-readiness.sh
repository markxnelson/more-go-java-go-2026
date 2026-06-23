#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
if [[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]]; then
  SCRIPT_DIR="."
fi
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/common.sh
source "${ROOT}/scripts/common.sh"

log "readiness_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "SOURCE_PACKAGE_STATUS=complete"

require_script() {
  local path="$1"
  [[ -f "${path}" ]] || die "required script missing: ${path}"
  [[ -x "${path}" ]] || die "required script is not executable: ${path}"
}

require_script "${ROOT}/scripts/build-go.sh"
require_script "${ROOT}/scripts/build-java.sh"
require_script "${ROOT}/scripts/build-loadgen.sh"
require_script "${ROOT}/scripts/start-go.sh"
require_script "${ROOT}/scripts/start-java.sh"
require_script "${ROOT}/scripts/stop-services.sh"
require_script "${ROOT}/scripts/run-smoke.sh"
require_script "${ROOT}/scripts/run-smoke-checks.sh"
require_script "${ROOT}/scripts/validate-equivalence.sh"
require_script "${ROOT}/scripts/sample-process.sh"
require_script "${ROOT}/scripts/validate-resource-sampler.sh"

if [[ -x "${ROOT}/scripts/drift-scan.sh" ]]; then
  "${ROOT}/scripts/drift-scan.sh"
fi

if [[ -x "${ROOT}/scripts/validate-fixtures.sh" ]]; then
  "${ROOT}/scripts/validate-fixtures.sh"
fi

"${ROOT}/scripts/validate-resource-sampler.sh"

if [[ -x "${ROOT}/scripts/test-go.sh" ]]; then
  "${ROOT}/scripts/test-go.sh"
fi

if [[ -x "${ROOT}/scripts/test-java.sh" ]]; then
  "${ROOT}/scripts/test-java.sh"
fi

if [[ -x "${ROOT}/scripts/test-loadgen.sh" ]]; then
  "${ROOT}/scripts/test-loadgen.sh"
fi

"${ROOT}/scripts/run-smoke.sh"
"${ROOT}/scripts/run-smoke-checks.sh"
"${ROOT}/scripts/validate-equivalence.sh"

log "readiness: pass"
