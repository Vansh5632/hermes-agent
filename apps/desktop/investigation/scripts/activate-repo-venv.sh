#!/usr/bin/env bash
# Activate repo venv (.venv from uv sync, or legacy venv/).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
if [[ -f "$REPO/.venv/bin/activate" ]]; then
  # shellcheck source=/dev/null
  source "$REPO/.venv/bin/activate"
elif [[ -f "$REPO/venv/bin/activate" ]]; then
  # shellcheck source=/dev/null
  source "$REPO/venv/bin/activate"
else
  echo "No Python venv at $REPO/.venv or $REPO/venv" >&2
  exit 1
fi
