#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

errors=0

newest_source() {
  local dir="$1"
  find "${dir}" -type f \
    ! -path '*/target/*' \
    ! -path '*/.cache/*' \
    ! -path '*/artifacts/*' \
    ! -path '*/manifests/*' \
    -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -n 1
}

check_newer_than_sources() {
  local artifact="$1"
  local source_dir="$2"
  local label="$3"

  if [[ ! -e "${artifact}" ]]; then
    return 0
  fi

  local source
  source="$(newest_source "${source_dir}" || true)"
  if [[ -z "${source}" ]]; then
    return 0
  fi

  if [[ "${source}" -nt "${artifact}" ]]; then
    printf 'ERROR: %s is stale: %s is newer than %s\n' "${label}" "${source}" "${artifact}" >&2
    errors=$((errors + 1))
  fi
}

check_manifest_after_file() {
  local manifest="$1"
  local dependency="$2"
  local label="$3"

  if [[ ! -f "${manifest}" || ! -e "${dependency}" ]]; then
    return 0
  fi

  if [[ "${dependency}" -nt "${manifest}" ]]; then
    printf 'ERROR: %s is stale: %s is newer than %s\n' "${label}" "${dependency}" "${manifest}" >&2
    errors=$((errors + 1))
  fi
}

check_newer_than_sources "${BIN_DIR}/go-http" "${ROOT}/services/go-http" "go service binary"
check_newer_than_sources "${BIN_DIR}/benchctl" "${ROOT}/tools/benchctl" "benchctl binary"
check_newer_than_sources "${BIN_DIR}/fast-echo" "${ROOT}/tools/fast-echo" "fast echo binary"
check_newer_than_sources "${ROOT}/services/java-helidon/target/java-helidon-1.0.0.jar" "${ROOT}/services/java-helidon" "Java service jar"

check_manifest_after_file "${ROOT}/manifests/environment.json" "${ROOT}/versions.env" "environment manifest"
check_manifest_after_file "${ROOT}/manifests/java-runtimes.json" "${ROOT}/scripts/discover-java-runtimes.sh" "Java runtime manifest"

if compgen -G "${ROOT}/manifests/profiled-run-*.json" >/dev/null; then
  while IFS= read -r manifest; do
    check_manifest_after_file "${manifest}" "${ROOT}/scripts/run-profiled-cells.sh" "profile manifest"
  done < <(find "${ROOT}/manifests" -maxdepth 1 -name 'profiled-run-*.json' -type f | sort)
fi

if [[ "${errors}" -ne 0 ]]; then
  die "artifact freshness check failed with ${errors} stale artifact(s)"
fi

log "artifact_freshness: pass"
