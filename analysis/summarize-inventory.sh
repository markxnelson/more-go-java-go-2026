#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/analysis/output}"
INVENTORY_FILE="$OUTPUT_DIR/inventory.json"

if [[ ! -f "$INVENTORY_FILE" ]]; then
  ARTIFACTS_DIR="${ARTIFACTS_DIR:-$ROOT_DIR/artifacts}" \
  MANIFESTS_DIR="${MANIFESTS_DIR:-$ROOT_DIR/manifests}" \
  OUTPUT_DIR="$OUTPUT_DIR" \
  "$ROOT_DIR/analysis/prepare-artifacts.sh" >/dev/null
fi

python3 - "$INVENTORY_FILE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
except OSError as exc:
    print(f"summarize-inventory: error: cannot read {path}: {exc}", file=sys.stderr)
    sys.exit(1)
except json.JSONDecodeError as exc:
    print(f"summarize-inventory: error: invalid JSON in {path}: {exc}", file=sys.stderr)
    sys.exit(1)

print(json.dumps(payload, indent=2, sort_keys=True))
PY
