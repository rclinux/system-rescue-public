#!/usr/bin/env bash
# Build a candidate ISO in project dist/; no block devices are accessed.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/../packaging/build_iso.py" "$@"
