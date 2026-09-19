#!/usr/bin/env bash
# Compare candidate payload, modes, ownership and launch settings with source.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/../packaging/verify_iso.py" "$@"
