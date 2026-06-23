#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

require_cmd java
require_cmd javac
require_cmd mvn

(
  cd "${ROOT}/services/java-helidon"
  mvn -q test
)

log "test-java: pass"
