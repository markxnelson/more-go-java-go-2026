#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
if [[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]]; then
  SCRIPT_DIR="."
fi
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

"${ROOT}/scripts/validate-fixtures.sh"
"${ROOT}/scripts/drift-scan.sh"
"${ROOT}/scripts/validate-resource-sampler.sh"
"${ROOT}/scripts/test-go.sh"
"${ROOT}/scripts/test-java.sh"
"${ROOT}/scripts/test-loadgen.sh"

if [[ -d "${ROOT}/tools/fast-echo" ]]; then
  (
    cd "${ROOT}/tools/fast-echo"
    go test ./...
  )
  echo "test-fast-echo: pass"
fi

echo "test-all: pass"
