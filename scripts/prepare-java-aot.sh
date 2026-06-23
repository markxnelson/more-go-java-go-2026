#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

AOT_KIND="${AOT_KIND:-openjdk}"

case "${AOT_KIND}" in
  openjdk|cds|appcds)
    exec "${ROOT}/scripts/prepare-openjdk-aot.sh" "$@"
    ;;
  oracle-jdk25|oracle25)
    exec "${ROOT}/scripts/prepare-oracle-jdk25-aot.sh" "$@"
    ;;
  *)
    die "unsupported AOT_KIND: ${AOT_KIND}; expected openjdk or oracle-jdk25"
    ;;
esac
