#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${ROOT}/scripts/common.sh"

SERVICE_NAME="java-helidon"
PID_FILE="${PID_DIR}/${SERVICE_NAME}.pid"
LOG_FILE="${LOG_DIR}/${SERVICE_NAME}.log"
COMMAND_ENV_FILE="${LOG_DIR}/${SERVICE_NAME}.command.env"
HEALTH_URL="http://127.0.0.1:${JAVA_PORT}/health"
JAR_PATH="${JAVA_JAR_PATH:-${ROOT}/services/java-helidon/target/java-helidon-1.0.0.jar}"

: "${JAVA_BINARY:=java}"
: "${JAVA_RUNTIME_ID:=path-java}"
: "${JAVA_VARIANT:=java-helidon}"
: "${JAVA_JVM_ARGS:=}"

mkdir -p "${PID_DIR}" "${LOG_DIR}"

if [[ "${JAVA_BINARY}" == */* ]]; then
  [[ -x "${JAVA_BINARY}" ]] || die "JAVA_BINARY is not executable: ${JAVA_BINARY}"
else
  command -v "${JAVA_BINARY}" >/dev/null 2>&1 || die "JAVA_BINARY not found on PATH: ${JAVA_BINARY}"
fi

"${ROOT}/scripts/build-java.sh" >/dev/null

[[ -f "${JAR_PATH}" ]] || die "Java service jar not found: ${JAR_PATH}"

stop_pid_file "${PID_FILE}"

EXTRA_JVM_ARGS=()

if [[ -n "${JAVA_GC_LOG_PATH:-}" ]]; then
  mkdir -p "$(dirname "${JAVA_GC_LOG_PATH}")"
  EXTRA_JVM_ARGS+=("-Xlog:gc*,safepoint:file=${JAVA_GC_LOG_PATH}:time,uptime,level,tags")
fi

if [[ -n "${JAVA_JFR_PATH:-}" ]]; then
  mkdir -p "$(dirname "${JAVA_JFR_PATH}")"
  JFR_SETTINGS="${JAVA_JFR_SETTINGS:-profile}"
  EXTRA_JVM_ARGS+=("-XX:StartFlightRecording=filename=${JAVA_JFR_PATH},settings=${JFR_SETTINGS},dumponexit=true")
fi

cat >"${COMMAND_ENV_FILE}" <<EOF
JAVA_BINARY=${JAVA_BINARY}
JAVA_RUNTIME_ID=${JAVA_RUNTIME_ID}
JAVA_VARIANT=${JAVA_VARIANT}
JAVA_JVM_ARGS=${JAVA_JVM_ARGS}
JAVA_GC_LOG_PATH=${JAVA_GC_LOG_PATH:-}
JAVA_JFR_PATH=${JAVA_JFR_PATH:-}
JAVA_PORT=${JAVA_PORT}
JAR_PATH=${JAR_PATH}
PID_FILE=${PID_FILE}
LOG_FILE=${LOG_FILE}
HEALTH_URL=${HEALTH_URL}
EOF

health_exact() {
  local body
  body="$(curl -fsS "${HEALTH_URL}" 2>/dev/null || true)"
  [[ "${body}" == '{"status":"ok"}' ]]
}

# JAVA_JVM_ARGS is intentionally split like normal shell arguments so callers can
# pass simple JVM flags without needing array syntax.
# shellcheck disable=SC2086
"${JAVA_BINARY}" ${JAVA_JVM_ARGS} "${EXTRA_JVM_ARGS[@]}" -jar "${JAR_PATH}" >"${LOG_FILE}" 2>&1 &
pid="$!"
echo "${pid}" >"${PID_FILE}"

for _ in {1..180}; do
  if health_exact; then
    log "java_service_port=${JAVA_PORT} pid=${pid} java_runtime_id=${JAVA_RUNTIME_ID} java_variant=${JAVA_VARIANT}"
    exit 0
  fi

  if ! kill -0 "${pid}" >/dev/null 2>&1; then
    rm -f "${PID_FILE}"
    die "Java service exited before becoming healthy; see ${LOG_FILE}"
  fi

  sleep 0.25
done

kill "${pid}" >/dev/null 2>&1 || true
rm -f "${PID_FILE}"
die "Timed out waiting for Java service health endpoint: ${HEALTH_URL}; see ${LOG_FILE}"
