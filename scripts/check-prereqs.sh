#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

required=(
  bash
  go
  java
  javac
  mvn
  curl
  jq
  python3
  rg
  awk
  sed
  wc
  uname
)

for cmd in "${required[@]}"; do
  require_cmd "${cmd}"
done

java_major_version() {
  java -version 2>&1 | awk -F '"' '
    /version/ {
      split($2, parts, ".")
      if (parts[1] == "1") {
        print parts[2]
      } else {
        print parts[1]
      }
      exit
    }
  '
}

required_java_release="$(version_env_value JAVA_RELEASE)"
detected_java_major="$(java_major_version || true)"

if [[ "${required_java_release}" != "unknown" && -n "${detected_java_major}" ]]; then
  if [[ "${detected_java_major}" =~ ^[0-9]+$ && "${required_java_release}" =~ ^[0-9]+$ ]]; then
    if (( detected_java_major < required_java_release )); then
      die "Java ${required_java_release}+ is required; detected Java ${detected_java_major}"
    fi
  fi
fi

log "prereqs: pass"
go version
java -version
javac -version
mvn -version | sed -n '1,3p'
curl --version | sed -n '1p'
jq --version
python3 --version
rg --version | sed -n '1p'

if awk --version >/dev/null 2>&1; then
  awk --version | sed -n '1p'
else
  log "awk available"
fi

if sed --version >/dev/null 2>&1; then
  sed --version | sed -n '1p'
else
  log "sed available"
fi

uname -a
