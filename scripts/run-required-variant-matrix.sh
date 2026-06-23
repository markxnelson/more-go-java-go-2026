#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISCOVER="${ROOT}/scripts/discover-java-runtimes.sh"
RUNNER="${ROOT}/scripts/run-benchmark-matrix.sh"
PREPARE_AOT="${ROOT}/scripts/prepare-jdk26-aot.sh"
RUNTIMES_MANIFEST="${ROOT}/manifests/java-runtimes.json"

if [[ ! -x "${DISCOVER}" ]]; then
  echo "ERROR: Missing executable runtime discovery script: ${DISCOVER}" >&2
  exit 1
fi

if [[ ! -x "${RUNNER}" ]]; then
  echo "ERROR: Missing executable benchmark matrix runner: ${RUNNER}" >&2
  exit 1
fi

if [[ ! -x "${PREPARE_AOT}" ]]; then
  echo "ERROR: Missing executable AOT preparation script: ${PREPARE_AOT}" >&2
  exit 1
fi

"${DISCOVER}"

echo "NOTE: Non-Oracle-built OpenJDK/Temurin variants are intentionally out of scope for this Oracle-built-JDK-only run." >&2

json_value() {
  local expression="$1"
  python3 - "${RUNTIMES_MANIFEST}" "${expression}" <<'PY'
import json
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expression = sys.argv[2]

def runtime_by_id(runtime_id):
    for runtime in manifest.get("javaRuntimes", []):
        if runtime.get("id") == runtime_id:
            return runtime
    return {}

if expression.startswith("recommended."):
    value = manifest.get("recommended", {}).get(expression.split(".", 1)[1])
elif expression.startswith("runtime."):
    _, runtime_id, field = expression.split(".", 2)
    value = runtime_by_id(runtime_id).get(field)
else:
    value = None

if value is None:
    sys.exit(0)
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

runtime_field() {
  local runtime_id="$1"
  local field="$2"
  json_value "runtime.${runtime_id}.${field}"
}

is_runtime_jdk26() {
  local runtime_id="$1"
  local version
  local text
  version="$(runtime_field "${runtime_id}" "javaVersion")"
  text="$(
    {
      runtime_field "${runtime_id}" "javaBinary"
      runtime_field "${runtime_id}" "javaHome"
      runtime_field "${runtime_id}" "versionLine"
    } | tr '[:upper:]' '[:lower:]'
  )"

  [[ "${version}" == 26 || "${version}" == 26.* || "${version}" == 26-* || "${text}" == *"jdk-26"* || "${text}" == *"openjdk-26"* ]]
}

ORACLE_JVM_ID="$(json_value "recommended.oracleJvm")"
ORACLE_AOT_ID="$(json_value "recommended.oracleAot")"

if [[ -z "${ORACLE_JVM_ID}" ]]; then
  echo "ERROR: No Oracle-built JDK runtime was discovered for oracle-jdk-26-jvm." >&2
  echo "Install Oracle JDK 26.0.1 or set JAVA_BINARY/ORACLE_JDK_HOME to that runtime, then retry." >&2
  exit 1
fi

if ! is_runtime_jdk26 "${ORACLE_JVM_ID}"; then
  echo "ERROR: Discovered Oracle runtime '${ORACLE_JVM_ID}' is not JDK 26; refusing to run variant oracle-jdk-26-jvm with the wrong runtime." >&2
  echo "Install Oracle JDK 26.0.1 or set JAVA_BINARY/ORACLE_JDK_HOME to that runtime, then retry." >&2
  exit 1
fi

if [[ -z "${ORACLE_AOT_ID}" ]]; then
  echo "ERROR: No Oracle-built JDK 26 runtime with AOT record support was discovered for oracle-jdk-26-aot." >&2
  echo "Install Oracle JDK 26.0.1 with JDK AOT support or set JAVA_BINARY/ORACLE_JDK_HOME to that runtime, then retry." >&2
  exit 1
fi

if ! is_runtime_jdk26 "${ORACLE_AOT_ID}"; then
  echo "ERROR: Discovered Oracle AOT runtime '${ORACLE_AOT_ID}' is not JDK 26; refusing to run variant oracle-jdk-26-aot with the wrong runtime." >&2
  echo "Install Oracle JDK 26.0.1 with JDK AOT support or set JAVA_BINARY/ORACLE_JDK_HOME to that runtime, then retry." >&2
  exit 1
fi

ORACLE_JVM_BINARY="$(runtime_field "${ORACLE_JVM_ID}" "javaBinary")"
ORACLE_AOT_BINARY="$(runtime_field "${ORACLE_AOT_ID}" "javaBinary")"

MANIFEST_OUT="${MANIFEST_OUT:-${ROOT}/artifacts/required-variant-matrix.csv}"
mkdir -p "$(dirname "${MANIFEST_OUT}")" "${ROOT}/artifacts/aot"

ORACLE_AOT_CACHE="${ORACLE_AOT_CACHE:-${ROOT}/artifacts/aot/oracle-jdk-26-aot.cache}"
ORACLE_AOT_MANIFEST="${ORACLE_AOT_MANIFEST:-${ROOT}/artifacts/aot/oracle-jdk-26-aot-manifest.json}"

"${PREPARE_AOT}" "${ORACLE_AOT_BINARY}" "${ORACLE_AOT_MANIFEST}" "${ORACLE_AOT_CACHE}"

next_manifest_mode="replace"

run_go_variant() {
  local variant="go-http"
  echo "Running required variant: ${variant}" >&2

  env \
    -u JAVA_BINARY \
    -u JAVA_RUNTIME_ID \
    -u JAVA_VARIANT \
    -u JAVA_JVM_ARGS \
    MANIFEST_OUT="${MANIFEST_OUT}" \
    MATRIX_MANIFEST_MODE="${next_manifest_mode}" \
    SERVICE_LIST="go" \
    BENCHMARK_RUNTIME="go" \
    RUNTIME="go" \
    VARIANT="${variant}" \
    BENCHMARK_VARIANT="${variant}" \
    MATRIX_VARIANT="${variant}" \
    SERVICE_VARIANT="${variant}" \
    GO_VARIANT="${variant}" \
    "${RUNNER}"

  next_manifest_mode="append"
}

run_java_variant() {
  local variant="$1"
  local java_binary="$2"
  local java_runtime_id="$3"
  local java_jvm_args="$4"

  echo "Running required variant: ${variant} with runtime ${java_runtime_id}" >&2

  env \
    MANIFEST_OUT="${MANIFEST_OUT}" \
    MATRIX_MANIFEST_MODE="${next_manifest_mode}" \
    SERVICE_LIST="java" \
    BENCHMARK_RUNTIME="java" \
    RUNTIME="java" \
    VARIANT="${variant}" \
    BENCHMARK_VARIANT="${variant}" \
    MATRIX_VARIANT="${variant}" \
    SERVICE_VARIANT="${variant}" \
    JAVA_BINARY="${java_binary}" \
    JAVA_RUNTIME_ID="${java_runtime_id}" \
    JAVA_VARIANT="${variant}" \
    JAVA_JVM_ARGS="${java_jvm_args}" \
    "${RUNNER}"

  next_manifest_mode="append"
}

ORACLE_JVM_ARGS="${ORACLE_JDK_26_JVM_ARGS:-${JAVA_JVM_ARGS:-}}"
ORACLE_AOT_ARGS="-XX:AOTMode=on -XX:AOTCache=${ORACLE_AOT_CACHE}"
if [[ -n "${ORACLE_JDK_26_AOT_EXTRA_ARGS:-}" ]]; then
  ORACLE_AOT_ARGS="${ORACLE_AOT_ARGS} ${ORACLE_JDK_26_AOT_EXTRA_ARGS}"
elif [[ -n "${JAVA_AOT_EXTRA_ARGS:-}" ]]; then
  ORACLE_AOT_ARGS="${ORACLE_AOT_ARGS} ${JAVA_AOT_EXTRA_ARGS}"
fi

run_go_variant
run_java_variant "oracle-jdk-26-jvm" "${ORACLE_JVM_BINARY}" "${ORACLE_JVM_ID}" "${ORACLE_JVM_ARGS}"
run_java_variant "oracle-jdk-26-aot" "${ORACLE_AOT_BINARY}" "${ORACLE_AOT_ID}" "${ORACLE_AOT_ARGS}"
