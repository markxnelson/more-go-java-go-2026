#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"${ROOT}/scripts/validate-fixtures.sh"
"${ROOT}/scripts/build-go.sh"
"${ROOT}/scripts/build-java.sh"
"${ROOT}/scripts/build-loadgen.sh"
"${ROOT}/scripts/build-fast-echo.sh"

printf '%s\n' "build-all: pass"
