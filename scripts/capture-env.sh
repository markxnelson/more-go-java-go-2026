#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

mkdir -p "${ROOT}/manifests"

bash "${ROOT}/scripts/discover-java-runtimes.sh"

helidon_version="$(grep -E '^HELIDON_VERSION=' "${ROOT}/versions.env" | cut -d= -f2-)"

go_version="$(go version | sed -n '1p')"
java_version="$(java -version 2>&1 | sed -n '1p')"
javac_version="$(javac -version 2>&1 | sed -n '1p')"
maven_version="$(mvn -version 2>&1 | sed -n '1p')"
kernel="$(uname -a)"
os_name="$(if [[ -f /etc/os-release ]]; then . /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}"; else printf 'unknown'; fi)"
cpu_model="$(awk -F: '/model name/ {gsub(/^ /,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
logical_cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 'unknown')"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
java_runtime_manifest="${ROOT}/manifests/java-runtimes.json"

TIMESTAMP="${timestamp}" \
PACKAGE_ROOT="${ROOT}" \
GO_VERSION="${go_version}" \
JAVA_VERSION="${java_version}" \
JAVAC_VERSION="${javac_version}" \
MAVEN_VERSION="${maven_version}" \
HELIDON_VERSION="${helidon_version}" \
OS_NAME="${os_name}" \
KERNEL="${kernel}" \
CPU_MODEL="${cpu_model}" \
LOGICAL_CPUS="${logical_cpus}" \
JAVA_RUNTIME_MANIFEST="${java_runtime_manifest}" \
python3 - "${ROOT}/manifests/environment.json" <<'PY'
import json
import os
import sys
from pathlib import Path

environment = {
    "timestampUtc": os.environ["TIMESTAMP"],
    "packageRoot": os.environ["PACKAGE_ROOT"],
    "javaRuntimeManifest": os.environ["JAVA_RUNTIME_MANIFEST"],
    "go": {
        "version": os.environ["GO_VERSION"],
    },
    "java": {
        "version": os.environ["JAVA_VERSION"],
        "javacVersion": os.environ["JAVAC_VERSION"],
    },
    "maven": {
        "version": os.environ["MAVEN_VERSION"],
    },
    "helidon": {
        "version": os.environ["HELIDON_VERSION"],
    },
    "os": {
        "name": os.environ["OS_NAME"],
        "kernel": os.environ["KERNEL"],
    },
    "cpu": {
        "model": os.environ["CPU_MODEL"],
        "logicalCpus": os.environ["LOGICAL_CPUS"],
    },
    "commands": {
        "capturedBy": "scripts/capture-env.sh",
    },
}

Path(sys.argv[1]).write_text(json.dumps(environment, indent=2) + "\n", encoding="utf-8")
PY

python3 -m json.tool "${ROOT}/manifests/environment.json" >/dev/null
log "environment_manifest=${ROOT}/manifests/environment.json"
