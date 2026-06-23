#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=scripts/common.sh

source "${ROOT}/scripts/common.sh"

ARTIFACTS_DIR="${ARTIFACTS_DIR:-${ROOT}/artifacts}"
RAW_DIR="${RAW_DIR:-${ARTIFACTS_DIR}/raw}"
SUMMARY_DIR="${SUMMARY_DIR:-${ARTIFACTS_DIR}/summary}"
PROCESS_DIR="${PROCESS_DIR:-${ARTIFACTS_DIR}/process}"
PROFILE_DIR="${PROFILE_DIR:-${ARTIFACTS_DIR}/profiles}"
MANIFESTS_DIR="${MANIFESTS_DIR:-${ROOT}/manifests}"
MANIFEST_OUT="${MANIFEST_OUT:-${MANIFESTS_DIR}/matrix-cells.csv}"
MATRIX_MANIFEST_MODE="${MATRIX_MANIFEST_MODE:-replace}"

BENCHCTL_BIN="${BENCHCTL_BIN:-${BIN_DIR}/benchctl}"

WARMUP_SECONDS="${WARMUP_SECONDS:-5}"
MEASURE_SECONDS="${MEASURE_SECONDS:-15}"
REPEATS="${REPEATS:-3}"
CONCURRENCY_LIST="${CONCURRENCY_LIST:-1 6 12}"
RATE_LIST="${RATE_LIST:-0}"
FIXTURE_LIST="${FIXTURE_LIST:-work-small work-medium}"
SERVICE_LIST="${SERVICE_LIST:-go java}"
CPU_SHAPE_LIST="${CPU_SHAPE_LIST:-all}"
SAMPLE_INTERVAL_SECONDS="${SAMPLE_INTERVAL_SECONDS:-1}"

ENABLE_PROFILES="${ENABLE_PROFILES:-0}"
PROFILED_SERVICE_LIST="${PROFILED_SERVICE_LIST:-go java}"
PROFILED_FIXTURE_LIST="${PROFILED_FIXTURE_LIST:-${FIXTURE_LIST}}"
PROFILED_REPEAT_LIST="${PROFILED_REPEAT_LIST:-1}"
GO_PROFILE_SECONDS="${GO_PROFILE_SECONDS:-${MEASURE_SECONDS}}"
GO_PROFILE_ENDPOINT_BASE="${GO_PROFILE_ENDPOINT_BASE:-}"

mkdir -p "${RAW_DIR}" "${SUMMARY_DIR}" "${PROCESS_DIR}" "${PROFILE_DIR}" "${MANIFESTS_DIR}"

cleanup() {
  set +e
  "${ROOT}/scripts/stop-services.sh" >/dev/null 2>&1 || true
}
trap cleanup EXIT

require_cmd() {
  local name="$1"
  command -v "${name}" >/dev/null 2>&1 || die "required command not found: ${name}"
}

require_file() {
  local path="$1"
  [[ -f "${path}" ]] || die "required file not found: ${path}"
}

contains_word() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "${item}" == "${needle}" ]] && return 0
  done
  return 1
}

split_words() {
  local input="$1"
  local -n output_ref="$2"
  read -r -a output_ref <<<"${input}"
}

online_cpu_count() {
  local count
  count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"

  if [[ "${count}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "${count}"
    return 0
  fi

  count="$(awk '/^processor[[:space:]]*:/ { n++ } END { if (n > 0) print n }' /proc/cpuinfo 2>/dev/null || true)"
  if [[ "${count}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "${count}"
    return 0
  fi

  die "unable to determine online logical CPU count"
}

cpu_shape_is_numeric() {
  local cpu_shape="$1"
  [[ "${cpu_shape}" =~ ^[1-9][0-9]*$ ]]
}

effective_cpu_list_for_shape() {
  local cpu_shape="$1"

  if [[ "${cpu_shape}" == "all" ]]; then
    printf 'all'
  else
    printf '0-%s' "$((cpu_shape - 1))"
  fi
}

java_cpu_arg_for_shape() {
  local cpu_shape="$1"

  if cpu_shape_is_numeric "${cpu_shape}"; then
    printf '%s' "-XX:ActiveProcessorCount=${cpu_shape}"
  fi
}

append_jvm_args() {
  local base="${1:-}"
  local extra="${2:-}"

  if [[ -n "${base}" && -n "${extra}" ]]; then
    printf '%s %s' "${base}" "${extra}"
  elif [[ -n "${base}" ]]; then
    printf '%s' "${base}"
  else
    printf '%s' "${extra}"
  fi
}

validate_cpu_shapes() {
  local online_cpus="$1"
  local cpu_shape

  for cpu_shape in ${CPU_SHAPE_LIST}; do
    if [[ "${cpu_shape}" == "all" ]]; then
      continue
    fi

    cpu_shape_is_numeric "${cpu_shape}" || die "invalid CPU shape: ${cpu_shape}"
    (( cpu_shape <= online_cpus )) || die "CPU shape ${cpu_shape} exceeds online logical CPU count ${online_cpus}"
    require_cmd taskset
  done
}

apply_cpu_shape_to_pid() {
  local cpu_shape="$1"
  local pid="$2"
  local cpu_list

  if [[ "${cpu_shape}" == "all" ]]; then
    return 0
  fi

  cpu_list="$(effective_cpu_list_for_shape "${cpu_shape}")"
  log "applying CPU affinity cpuShape=${cpu_shape} cpuList=${cpu_list} pid=${pid}"
  taskset -pc "${cpu_list}" "${pid}" >&2
}

csv_escape() {
  local value="${1:-}"
  value="${value//\"/\"\"}"
  printf '"%s"' "${value}"
}

init_manifest() {
  local header
  header="timestampUtc,service,resultService,variant,cpuShape,effectiveCpuList,fixture,concurrency,rate,repeat,servicePid,rawArtifact,summaryArtifact,serviceProcessArtifact,loadgenProcessArtifact,javaGcLogArtifact,javaJfrArtifact,goCpuProfileArtifact,goHeapProfileArtifact,goRuntimeMetricsArtifact"

  case "${MATRIX_MANIFEST_MODE}" in
    replace)
      printf '%s\n' "${header}" >"${MANIFEST_OUT}"
      ;;
    append)
      if [[ ! -s "${MANIFEST_OUT}" ]]; then
        printf '%s\n' "${header}" >"${MANIFEST_OUT}"
      fi
      ;;
    *)
      die "invalid MATRIX_MANIFEST_MODE: ${MATRIX_MANIFEST_MODE}; expected replace or append"
      ;;
  esac
}

append_manifest_row() {
  local timestamp_utc="$1"
  local service="$2"
  local result_service="$3"
  local variant="$4"
  local cpu_shape="$5"
  local effective_cpu_list="$6"
  local fixture="$7"
  local concurrency="$8"
  local rate="$9"
  local repeat="${10}"
  local service_pid="${11}"
  local raw_artifact="${12}"
  local summary_artifact="${13}"
  local service_process_artifact="${14}"
  local loadgen_process_artifact="${15}"
  local java_gc_log_artifact="${16}"
  local java_jfr_artifact="${17}"
  local go_cpu_profile_artifact="${18}"
  local go_heap_profile_artifact="${19}"
  local go_runtime_metrics_artifact="${20}"

  {
    csv_escape "${timestamp_utc}"; printf ','
    csv_escape "${service}"; printf ','
    csv_escape "${result_service}"; printf ','
    csv_escape "${variant}"; printf ','
    csv_escape "${cpu_shape}"; printf ','
    csv_escape "${effective_cpu_list}"; printf ','
    csv_escape "${fixture}"; printf ','
    csv_escape "${concurrency}"; printf ','
    csv_escape "${rate}"; printf ','
    csv_escape "${repeat}"; printf ','
    csv_escape "${service_pid}"; printf ','
    csv_escape "${raw_artifact}"; printf ','
    csv_escape "${summary_artifact}"; printf ','
    csv_escape "${service_process_artifact}"; printf ','
    csv_escape "${loadgen_process_artifact}"; printf ','
    csv_escape "${java_gc_log_artifact}"; printf ','
    csv_escape "${java_jfr_artifact}"; printf ','
    csv_escape "${go_cpu_profile_artifact}"; printf ','
    csv_escape "${go_heap_profile_artifact}"; printf ','
    csv_escape "${go_runtime_metrics_artifact}"; printf '\n'
  } >>"${MANIFEST_OUT}"
}

result_service_for_service() {
  local service="$1"

  case "${service}" in
    go)
      printf 'go'
      ;;
    java)
      printf 'java'
      ;;
    *)
      die "unsupported service in SERVICE_LIST: ${service}"
      ;;
  esac
}

variant_for_service() {
  local service="$1"

  case "${service}" in
    go)
      printf 'go-http'
      ;;
    java)
      printf '%s' "${JAVA_VARIANT:-java-helidon}"
      ;;
    *)
      die "unsupported service in SERVICE_LIST: ${service}"
      ;;
  esac
}

pid_file_for_service() {
  local service="$1"

  case "${service}" in
    go)
      printf '%s' "${PID_DIR}/go-http.pid"
      ;;
    java)
      printf '%s' "${PID_DIR}/java-helidon.pid"
      ;;
    *)
      die "unsupported service in SERVICE_LIST: ${service}"
      ;;
  esac
}

url_for_service() {
  local service="$1"

  case "${service}" in
    go)
      printf 'http://127.0.0.1:%s/work' "${GO_PORT}"
      ;;
    java)
      printf 'http://127.0.0.1:%s/work' "${JAVA_PORT}"
      ;;
    *)
      die "unsupported service in SERVICE_LIST: ${service}"
      ;;
  esac
}

health_port_for_service() {
  local service="$1"

  case "${service}" in
    go)
      printf '%s' "${GO_PORT}"
      ;;
    java)
      printf '%s' "${JAVA_PORT}"
      ;;
    *)
      die "unsupported service in SERVICE_LIST: ${service}"
      ;;
  esac
}

read_pid_with_wait() {
  local pid_file="$1"

  for _ in {1..120}; do
    if [[ -f "${pid_file}" ]]; then
      local pid
      pid="$(tr -d '[:space:]' <"${pid_file}" || true)"
      if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" >/dev/null 2>&1; then
        printf '%s' "${pid}"
        return 0
      fi
    fi

    sleep 0.25
  done

  return 1
}

rate_is_valid() {
  local rate="$1"
  awk -v r="${rate}" 'BEGIN { exit (r ~ /^[0-9]+([.][0-9]+)?$/ ? 0 : 1) }'
}

rate_is_positive() {
  local rate="$1"
  awk -v r="${rate}" 'BEGIN { exit ((r ~ /^[0-9]+([.][0-9]+)?$/ && r + 0 > 0) ? 0 : 1) }'
}

token_for_value() {
  local token="$1"
  token="${token//./p}"
  token="${token//:/_}"
  token="${token//\//_}"
  token="${token// /_}"
  printf '%s' "${token}" | tr -c 'A-Za-z0-9_-' '_'
}

ensure_process_sample_header() {
  local path="$1"

  if [[ -s "${path}" ]]; then
    return 0
  fi

  printf 'timestampUnixNano,pid,rssKiB,vsizeKiB,userTicks,systemTicks,threads,fdCount\n' >"${path}"
}

profile_selected() {
  local service="$1"
  local fixture="$2"
  local repeat="$3"

  [[ "${ENABLE_PROFILES}" == "1" ]] || return 1

  local services
  local fixtures
  local repeats
  split_words "${PROFILED_SERVICE_LIST}" services
  split_words "${PROFILED_FIXTURE_LIST}" fixtures
  split_words "${PROFILED_REPEAT_LIST}" repeats

  contains_word "${service}" "${services[@]}" || return 1
  contains_word "${fixture}" "${fixtures[@]}" || return 1
  contains_word "${repeat}" "${repeats[@]}" || return 1

  return 0
}

start_service() {
  local service="$1"
  local cpu_shape="$2"
  local java_gc_log_path="${3:-}"
  local java_jfr_path="${4:-}"
  local java_cpu_arg

  java_cpu_arg="$(java_cpu_arg_for_shape "${cpu_shape}")"

  case "${service}" in
    go)
      if cpu_shape_is_numeric "${cpu_shape}"; then
        GOMAXPROCS="${cpu_shape}" "${ROOT}/scripts/start-go.sh"
      else
        "${ROOT}/scripts/start-go.sh"
      fi
      ;;
    java)
      if [[ -n "${java_cpu_arg}" ]]; then
        JAVA_JVM_ARGS="$(append_jvm_args "${JAVA_JVM_ARGS:-}" "${java_cpu_arg}")" \
        JAVA_GC_LOG_PATH="${java_gc_log_path}" \
        JAVA_JFR_PATH="${java_jfr_path}" \
        "${ROOT}/scripts/start-java.sh"
      else
        JAVA_GC_LOG_PATH="${java_gc_log_path}" \
        JAVA_JFR_PATH="${java_jfr_path}" \
        "${ROOT}/scripts/start-java.sh"
      fi
      ;;
    *)
      die "unsupported service in SERVICE_LIST: ${service}"
      ;;
  esac
}

go_profile_base_url() {
  local service="$1"
  local port

  if [[ -n "${GO_PROFILE_ENDPOINT_BASE}" ]]; then
    printf '%s' "${GO_PROFILE_ENDPOINT_BASE}"
    return 0
  fi

  port="$(health_port_for_service "${service}")"
  printf 'http://127.0.0.1:%s' "${port}"
}

start_go_cpu_profile() {
  local service="$1"
  local output="$2"
  local base_url

  base_url="$(go_profile_base_url "${service}")"
  mkdir -p "$(dirname "${output}")"

  curl -fsS "${base_url}/debug/pprof/profile?seconds=${GO_PROFILE_SECONDS}" -o "${output}" >/dev/null 2>&1 &
  STARTED_GO_CPU_PROFILE_PID="$!"
}

collect_go_heap_profile() {
  local service="$1"
  local output="$2"
  local base_url

  base_url="$(go_profile_base_url "${service}")"
  mkdir -p "$(dirname "${output}")"

  if ! curl -fsS "${base_url}/debug/pprof/heap" -o "${output}" >/dev/null 2>&1; then
    rm -f "${output}"
    return 1
  fi
}

collect_go_runtime_metrics() {
  local service="$1"
  local output="$2"
  local base_url

  base_url="$(go_profile_base_url "${service}")"
  mkdir -p "$(dirname "${output}")"

  if curl -fsS "${base_url}/debug/runtime-metrics" -o "${output}" >/dev/null 2>&1; then
    return 0
  fi

  if curl -fsS "${base_url}/debug/vars" -o "${output}" >/dev/null 2>&1; then
    return 0
  fi

  rm -f "${output}"
  return 1
}

require_cmd curl
require_cmd awk
require_file "${ROOT}/scripts/start-go.sh"
require_file "${ROOT}/scripts/start-java.sh"
require_file "${ROOT}/scripts/stop-services.sh"
require_file "${ROOT}/scripts/sample-process.sh"

"${ROOT}/scripts/build-loadgen.sh" >/dev/null
[[ -x "${BENCHCTL_BIN}" ]] || die "benchctl binary not found or not executable: ${BENCHCTL_BIN}"

ONLINE_CPU_COUNT="$(online_cpu_count)"
validate_cpu_shapes "${ONLINE_CPU_COUNT}"
init_manifest

for service in ${SERVICE_LIST}; do
  result_service="$(result_service_for_service "${service}")"

  for cpu_shape in ${CPU_SHAPE_LIST}; do
    effective_cpu_list="$(effective_cpu_list_for_shape "${cpu_shape}")"

    for fixture in ${FIXTURE_LIST}; do
      fixture_path="${ROOT}/fixtures/valid/${fixture}.json"
      require_file "${fixture_path}"

      for concurrency in ${CONCURRENCY_LIST}; do
        for rate in ${RATE_LIST}; do
          rate_is_valid "${rate}" || die "invalid rate in RATE_LIST: ${rate}"

          rate_token="$(token_for_value "${rate}")"
          cpu_token="$(token_for_value "${cpu_shape}")"
          cell="${fixture}-cpu${cpu_token}-c${concurrency}-rate${rate_token}"

          for repeat in $(seq 1 "${REPEATS}"); do
            variant="$(variant_for_service "${service}")"

            raw_out="${RAW_DIR}/${result_service}_${variant}_${cell}_r${repeat}.jsonl"
            summary_out="${SUMMARY_DIR}/${result_service}_${variant}_${cell}_r${repeat}.json"
            service_process_out="${PROCESS_DIR}/${result_service}_${variant}_${cell}_service_r${repeat}.csv"
            loadgen_process_out="${PROCESS_DIR}/${result_service}_${variant}_${cell}_loadgen_r${repeat}.csv"

            java_gc_log_target=""
            java_jfr_target=""
            go_cpu_profile_target=""
            go_heap_profile_target=""
            go_runtime_metrics_target=""

            if profile_selected "${service}" "${fixture}" "${repeat}"; then
              case "${service}" in
                java)
                  java_gc_log_target="${PROFILE_DIR}/java/${result_service}_${variant}_${cell}_r${repeat}.gc.log"
                  if [[ "${variant}" != *aot* || "${ENABLE_AOT_JFR:-0}" = "1" ]]; then
                    java_jfr_target="${PROFILE_DIR}/java/${result_service}_${variant}_${cell}_r${repeat}.jfr"
                  fi
                  ;;
                go)
                  go_cpu_profile_target="${PROFILE_DIR}/go/${result_service}_${variant}_${cell}_r${repeat}.cpu.pprof"
                  go_heap_profile_target="${PROFILE_DIR}/go/${result_service}_${variant}_${cell}_r${repeat}.heap.pprof"
                  go_runtime_metrics_target="${PROFILE_DIR}/go/${result_service}_${variant}_${cell}_r${repeat}.runtime-metrics.json"
                  ;;
              esac
            fi

            rm -f \
              "${raw_out}" \
              "${summary_out}" \
              "${service_process_out}" \
              "${loadgen_process_out}" \
              "${java_gc_log_target}" \
              "${java_jfr_target}" \
              "${go_cpu_profile_target}" \
              "${go_heap_profile_target}" \
              "${go_runtime_metrics_target}"

            "${ROOT}/scripts/stop-services.sh" >/dev/null 2>&1 || true

            log "starting service=${service} variant=${variant} cpuShape=${cpu_shape} fixture=${fixture} concurrency=${concurrency} rate=${rate} repeat=${repeat}"
            start_service "${service}" "${cpu_shape}" "${java_gc_log_target}" "${java_jfr_target}" >/dev/null

            pid_file="$(pid_file_for_service "${service}")"
            pid="$(read_pid_with_wait "${pid_file}")" || die "failed to obtain live pid from ${pid_file}"

            apply_cpu_shape_to_pid "${cpu_shape}" "${pid}"

            sample_duration="$(( WARMUP_SECONDS + MEASURE_SECONDS + 3 ))"

            "${ROOT}/scripts/sample-process.sh" -pid "${pid}" -out "${service_process_out}" -duration "${sample_duration}" -interval "${SAMPLE_INTERVAL_SECONDS}" &
            service_sampler_pid="$!"

            go_cpu_profile_pid=""
            if [[ -n "${go_cpu_profile_target}" ]]; then
              start_go_cpu_profile "${service}" "${go_cpu_profile_target}"
              go_cpu_profile_pid="${STARTED_GO_CPU_PROFILE_PID}"
            fi

            bench_cmd=(
              "${BENCHCTL_BIN}"
              -url "$(url_for_service "${service}")"
              -fixture "${fixture_path}"
              -out "${raw_out}"
              -warmup "${WARMUP_SECONDS}s"
              -duration "${MEASURE_SECONDS}s"
              -concurrency "${concurrency}"
              -service "${result_service}"
              -variant "${variant}"
              -cell "${cell}"
              -repeat "${repeat}"
              -summary-out "${summary_out}"
            )

            if rate_is_positive "${rate}"; then
              bench_cmd+=(-rate "${rate}")
            fi

            "${bench_cmd[@]}" &
            bench_pid="$!"

            "${ROOT}/scripts/sample-process.sh" -pid "${bench_pid}" -out "${loadgen_process_out}" -duration "${sample_duration}" -interval "${SAMPLE_INTERVAL_SECONDS}" &
            loadgen_sampler_pid="$!"

            set +e
            wait "${bench_pid}"
            bench_rc="$?"

            wait "${service_sampler_pid}"
            service_sampler_rc="$?"

            wait "${loadgen_sampler_pid}"
            loadgen_sampler_rc="$?"

            if [[ -n "${go_cpu_profile_pid}" ]]; then
              wait "${go_cpu_profile_pid}"
              go_cpu_profile_rc="$?"
            else
              go_cpu_profile_rc="0"
            fi
            set -e

            ensure_process_sample_header "${service_process_out}"
            ensure_process_sample_header "${loadgen_process_out}"

            if [[ -n "${go_heap_profile_target}" ]]; then
              collect_go_heap_profile "${service}" "${go_heap_profile_target}" || log "warning: Go heap profile endpoint did not produce ${go_heap_profile_target}"
            fi

            if [[ -n "${go_runtime_metrics_target}" ]]; then
              collect_go_runtime_metrics "${service}" "${go_runtime_metrics_target}" || log "warning: Go runtime metrics endpoint did not produce ${go_runtime_metrics_target}"
            fi

            [[ "${service_sampler_rc}" == "0" ]] || log "warning: service sampler exited rc=${service_sampler_rc}"
            [[ "${loadgen_sampler_rc}" == "0" ]] || log "warning: loadgen sampler exited rc=${loadgen_sampler_rc}"
            [[ "${go_cpu_profile_rc}" == "0" ]] || log "warning: Go CPU profile endpoint did not produce ${go_cpu_profile_target}"

            # Stop services first so JVM exit-time artifacts, especially JFR dumponexit files, flush before manifest capture.
            "${ROOT}/scripts/stop-services.sh" >/dev/null 2>&1 || true

            java_gc_log_artifact=""
            java_jfr_artifact=""
            go_cpu_profile_artifact=""
            go_heap_profile_artifact=""
            go_runtime_metrics_artifact=""

            [[ -n "${java_gc_log_target}" && -s "${java_gc_log_target}" ]] && java_gc_log_artifact="${java_gc_log_target}"
            [[ -n "${java_jfr_target}" && -s "${java_jfr_target}" ]] && java_jfr_artifact="${java_jfr_target}"
            [[ -n "${go_cpu_profile_target}" && -s "${go_cpu_profile_target}" ]] && go_cpu_profile_artifact="${go_cpu_profile_target}"
            [[ -n "${go_heap_profile_target}" && -s "${go_heap_profile_target}" ]] && go_heap_profile_artifact="${go_heap_profile_target}"
            [[ -n "${go_runtime_metrics_target}" && -s "${go_runtime_metrics_target}" ]] && go_runtime_metrics_artifact="${go_runtime_metrics_target}"

            append_manifest_row \
              "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
              "${service}" \
              "${result_service}" \
              "${variant}" \
              "${cpu_shape}" \
              "${effective_cpu_list}" \
              "${fixture}" \
              "${concurrency}" \
              "${rate}" \
              "${repeat}" \
              "${pid}" \
              "${raw_out}" \
              "${summary_out}" \
              "${service_process_out}" \
              "${loadgen_process_out}" \
              "${java_gc_log_artifact}" \
              "${java_jfr_artifact}" \
              "${go_cpu_profile_artifact}" \
              "${go_heap_profile_artifact}" \
              "${go_runtime_metrics_artifact}"

            if [[ "${bench_rc}" != "0" ]]; then
              "${ROOT}/scripts/stop-services.sh" >/dev/null 2>&1 || true
              die "benchctl failed for service=${service} cell=${cell} repeat=${repeat} rc=${bench_rc}"
            fi

            [[ -s "${raw_out}" ]] || log "warning: raw output missing or empty: ${raw_out}"
            [[ -s "${summary_out}" ]] || log "warning: summary output missing or empty: ${summary_out}"

            "${ROOT}/scripts/stop-services.sh" >/dev/null 2>&1 || true
          done
        done
      done
    done
  done
done

log "benchmark_matrix_manifest=${MANIFEST_OUT}"
log "benchmark_matrix_status=raw_artifacts_written_no_interpretation"
