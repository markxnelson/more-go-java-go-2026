#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="${BASH_SOURCE[0]}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
if [[ "${SCRIPT_DIR}" == "${SCRIPT_PATH}" ]]; then
  SCRIPT_DIR="."
fi
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SAMPLER="${ROOT}/scripts/sample-process.sh"
OUT="/tmp/validate-resource-sampler-${$}.csv"

if [[ ! -d /proc || ! -r /proc/uptime || ! -r /proc/stat ]]; then
  echo "validate-resource-sampler: Linux /proc is required" >&2
  exit 2
fi

if [[ ! -f "${SAMPLER}" ]]; then
  echo "validate-resource-sampler: missing sampler: ${SAMPLER}" >&2
  exit 2
fi

sleep 5 &
target_pid="$!"

cleanup() {
  if [[ -n "${target_pid:-}" && -d "/proc/${target_pid}" ]]; then
    kill "${target_pid}" 2>/dev/null || true
    wait "${target_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM HUP

if [[ ! -d "/proc/${target_pid}" ]]; then
  echo "validate-resource-sampler: failed to start validation process" >&2
  exit 1
fi

bash "${SAMPLER}" -pid "${target_pid}" -out "${OUT}" -interval 0.1 -duration 1

if [[ ! -s "${OUT}" ]]; then
  echo "validate-resource-sampler: sampler did not write output" >&2
  exit 1
fi

awk -F, '
  BEGIN {
    expected = "timestampUnixNano,pid,rssKiB,vsizeKiB,userTicks,systemTicks,threads,fdCount"
  }

  NR == 1 {
    if ($0 != expected) {
      print "validate-resource-sampler: unexpected CSV header: " $0 > "/dev/stderr"
      failed = 10
      exit failed
    }
    next
  }

  NF == 8 {
    rows++
    if (($3 + 0) > 0) {
      rss_nonzero = 1
    }
    if (($4 + 0) > 0) {
      vsize_nonzero = 1
    }
    next
  }

  {
    print "validate-resource-sampler: malformed CSV row: " $0 > "/dev/stderr"
    failed = 11
    exit failed
  }

  END {
    if (failed) {
      exit failed
    }
    if (NR <= 1 || rows < 1) {
      print "validate-resource-sampler: no telemetry rows were written" > "/dev/stderr"
      exit 12
    }
    if (!rss_nonzero) {
      print "validate-resource-sampler: rssKiB remained zero for a live process" > "/dev/stderr"
      exit 13
    }
    if (!vsize_nonzero) {
      print "validate-resource-sampler: vsizeKiB remained zero for a live process" > "/dev/stderr"
      exit 14
    }
  }
' "${OUT}"

echo "validate-resource-sampler: pass"
