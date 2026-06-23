#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT}/scripts/common.sh"

output="${1:-}"

make_report() {
  python3 - "${ROOT}" <<'PY'
import hashlib
import os
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
exclude_parts = {
    ".cache",
    "target",
    ".git",
    "__pycache__",
}
exclude_prefixes = (
    "artifacts/raw/",
    "artifacts/logs/",
    "artifacts/tmp/",
    "artifacts/profiles/",
    "artifacts/aot/",
)

files = []
for path in root.rglob("*"):
    if not path.is_file():
        continue
    rel = path.relative_to(root).as_posix()
    if any(part in exclude_parts for part in path.relative_to(root).parts):
        continue
    if any(rel.startswith(prefix) for prefix in exclude_prefixes):
        continue
    if rel.endswith((".jsonl", ".csv")) and rel.startswith("artifacts/"):
        continue
    files.append(rel)

files.sort()

def sha256(path):
    h = hashlib.sha256()
    with (root / path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def first_line(command):
    try:
        proc = subprocess.run(command, cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)
        for line in proc.stdout.splitlines():
            if line.strip():
                return line.strip()
    except FileNotFoundError:
        return "not-found"
    return "unknown"

print("# Materialization Report")
print()
print(f"- packageRoot: `{root}`")
print(f"- fileCount: `{len(files)}`")
print(f"- go: `{first_line(['go', 'version'])}`")
print(f"- java: `{first_line(['java', '-version'])}`")
print(f"- maven: `{first_line(['mvn', '-version'])}`")
print()
print("## Version metadata")
versions = root / "versions.env"
if versions.exists():
    for line in versions.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            print(f"- `{line}`")
else:
    print("- missing versions.env")
print()
print("## Source files")
for rel in files:
    print(f"- `{rel}` `{sha256(rel)}`")
PY
}

if [[ -n "${output}" ]]; then
  mkdir -p "$(dirname "${output}")"
  make_report > "${output}"
  log "materialization_report=${output}"
else
  make_report
fi
