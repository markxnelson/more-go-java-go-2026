#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${ROOT}/scripts/common.sh" ]]; then
  source "${ROOT}/scripts/common.sh"
else
  log() {
    printf '%s\n' "$*"
  }
fi

if [[ -x "${ROOT}/scripts/stop-services.sh" ]]; then
  "${ROOT}/scripts/stop-services.sh" >/dev/null 2>&1 || true
fi

rm -rf "${ROOT}/.cache"

for dir in \
  "${ROOT}/artifacts/logs" \
  "${ROOT}/artifacts/raw" \
  "${ROOT}/artifacts/tmp" \
  "${ROOT}/artifacts/profiles" \
  "${ROOT}/artifacts/aot"
do
  if [[ -d "${dir}" ]]; then
    find "${dir}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi
done

if [[ -d "${ROOT}/manifests" ]]; then
  find "${ROOT}/manifests" -maxdepth 1 -type f \( \
    -name 'environment.json' -o \
    -name 'java-runtimes.json' -o \
    -name 'headroom-*.json' -o \
    -name 'rate-selection-*.json' -o \
    -name 'profiled-run-*.json' -o \
    -name 'provisioned-openjdk-*.json' \
  \) -delete
fi

if [[ -d "${ROOT}/services/java-helidon/target" ]]; then
  rm -rf "${ROOT}/services/java-helidon/target"
fi

log "clean: pass"
