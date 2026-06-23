#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: sample-process.sh -pid PID -out PATH [-interval SECONDS] [-duration SECONDS]" >&2
  echo "" >&2
  echo "Writes process telemetry as canonical CSV. The script stops when the process exits," >&2
  echo "when the optional duration elapses, or when this sampler receives a termination" >&2
  echo "signal." >&2
  echo "" >&2
  echo "Canonical CSV schema:" >&2
  echo "timestampUnixNano,pid,rssKiB,vsizeKiB,userTicks,systemTicks,threads,fdCount" >&2
}

pid=""
out=""
interval="1"
duration=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -pid|--pid)
      pid="${2:-}"
      shift 2
      ;;
    -out|--out)
      out="${2:-}"
      shift 2
      ;;
    -interval|--interval)
      interval="${2:-}"
      shift 2
      ;;
    -duration|--duration)
      duration="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "${pid}" || -z "${out}" ]]; then
  usage
  exit 2
fi

if ! [[ "${pid}" =~ ^[0-9]+$ ]]; then
  echo "pid must be numeric: ${pid}" >&2
  exit 2
fi

if ! [[ "${interval}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "interval must be a non-negative number of seconds: ${interval}" >&2
  exit 2
fi

if [[ -n "${duration}" ]] && ! [[ "${duration}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "duration must be a non-negative number of seconds: ${duration}" >&2
  exit 2
fi

if [[ ! -d /proc || ! -r /proc/uptime || ! -r /proc/stat ]]; then
  echo "sample-process.sh requires Linux /proc" >&2
  exit 2
fi

out_dir="${out%/*}"
if [[ -n "${out_dir}" && "${out_dir}" != "${out}" && ! -d "${out_dir}" ]]; then
  mkdir -p "${out_dir}"
fi

echo "timestampUnixNano,pid,rssKiB,vsizeKiB,userTicks,systemTicks,threads,fdCount" > "${out}"

stop="0"
trap 'stop=1' TERM INT HUP

boot_time_seconds="$(awk '/^btime[[:space:]]+/ { print $2; exit }' /proc/stat)"
if [[ -z "${boot_time_seconds}" || ! "${boot_time_seconds}" =~ ^[0-9]+$ ]]; then
  echo "unable to read boot time from /proc/stat" >&2
  exit 1
fi

uptime_seconds() {
  awk '{ print $1; exit }' /proc/uptime
}

now_unix_nano() {
  local up
  local whole
  local frac
  local seconds

  up="$(uptime_seconds)"
  if [[ "${up}" == *.* ]]; then
    whole="${up%%.*}"
    frac="${up#*.}"
  else
    whole="${up}"
    frac="0"
  fi

  if [[ -z "${whole}" || ! "${whole}" =~ ^[0-9]+$ ]]; then
    whole="0"
  fi

  frac="${frac}000000000"
  frac="${frac:0:9}"
  seconds=$((10#${boot_time_seconds} + 10#${whole}))
  echo "${seconds}${frac}"
}

duration_reached() {
  local now="$1"
  local start="$2"
  local limit="$3"

  awk -v now="${now}" -v start="${start}" -v limit="${limit}" 'BEGIN { exit((now - start) >= limit ? 0 : 1) }'
}

start_uptime="$(uptime_seconds)"
shopt -s nullglob

while [[ "${stop}" == "0" ]]; do
  if [[ ! -d "/proc/${pid}" ]]; then
    break
  fi

  current_uptime="$(uptime_seconds)"
  if [[ -n "${duration}" ]] && duration_reached "${current_uptime}" "${start_uptime}" "${duration}"; then
    break
  fi

  timestamp_unix_nano="$(now_unix_nano)"

  rss_kib="0"
  vsize_kib="0"
  threads="0"
  user_ticks="0"
  system_ticks="0"
  fd_count="0"

  status_path="/proc/${pid}/status"
  if [[ -r "${status_path}" ]]; then
    while read -r key value rest || [[ -n "${key:-}" ]]; do
      case "${key}" in
        VmRSS:)
          if [[ "${value:-}" =~ ^[0-9]+$ ]]; then
            rss_kib="${value}"
          fi
          ;;
        VmSize:)
          if [[ "${value:-}" =~ ^[0-9]+$ ]]; then
            vsize_kib="${value}"
          fi
          ;;
        Threads:)
          if [[ "${value:-}" =~ ^[0-9]+$ ]]; then
            threads="${value}"
          fi
          ;;
      esac
    done < "${status_path}" 2>/dev/null || true
  fi

  stat_path="/proc/${pid}/stat"
  if [[ -r "${stat_path}" ]]; then
    if stat_content="$(<"${stat_path}")"; then
      stat_after_comm="${stat_content#*) }"
      if [[ "${stat_after_comm}" != "${stat_content}" ]]; then
        read -r -a stat_fields <<< "${stat_after_comm}"
        if [[ "${#stat_fields[@]}" -ge 13 ]]; then
          if [[ "${stat_fields[11]}" =~ ^[0-9]+$ ]]; then
            user_ticks="${stat_fields[11]}"
          fi
          if [[ "${stat_fields[12]}" =~ ^[0-9]+$ ]]; then
            system_ticks="${stat_fields[12]}"
          fi
        fi
      fi
    fi
  fi

  if [[ -d "/proc/${pid}/fd" ]]; then
    fd_entries=(/proc/"${pid}"/fd/*)
    fd_count="${#fd_entries[@]}"
  fi

  echo "${timestamp_unix_nano},${pid},${rss_kib},${vsize_kib},${user_ticks},${system_ticks},${threads},${fd_count}" >> "${out}"

  sleep "${interval}" || break
done
