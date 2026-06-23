#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

JAVA_BINARY="${JAVA_BINARY:-java}"
AOT_RUNTIME_ID="${AOT_RUNTIME_ID:-oracle-jdk25-cds}"
AOT_OUTPUT_SUBDIR="${AOT_OUTPUT_SUBDIR:-oracle-jdk25}"

if [[ "${JAVA_BINARY}" == */* ]]; then
  [[ -x "${JAVA_BINARY}" ]] || die "JAVA_BINARY is not executable: ${JAVA_BINARY}"
else
  command -v "${JAVA_BINARY}" >/dev/null 2>&1 || die "JAVA_BINARY not found on PATH: ${JAVA_BINARY}"
fi

version_text="$("${JAVA_BINARY}" -version 2>&1 | tr '\n' ' ')"
if [[ "${version_text}" != *'"25'* && "${ALLOW_NON_JDK25:-0}" != "1" ]]; then
  die "JAVA_BINARY does not appear to be JDK 25; set ALLOW_NON_JDK25=1 to prepare the generic CDS archive anyway"
fi

export JAVA_BINARY
export AOT_RUNTIME_ID
export AOT_OUTPUT_SUBDIR

"${ROOT}/scripts/prepare-openjdk-aot.sh" "$@"
