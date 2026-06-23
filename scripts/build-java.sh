#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

require_cmd java
require_cmd javac
require_cmd mvn

(
  cd "${ROOT}/services/java-helidon"
  mvn -q -DskipTests package
)

log "build-java: pass"
log "service_dir=${ROOT}/services/java-helidon"
