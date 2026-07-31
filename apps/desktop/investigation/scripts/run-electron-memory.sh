#!/usr/bin/env bash
# Run E: Electron dev memory sample (591 MB fixture + Playwright MCP).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TEST_HOME="${HERMES_MEM_TEST_HOME:-/tmp/hermes-mem-test}"
LOG_DIR="$TEST_HOME/logs"
DESKTOP_LOG="$TEST_HOME/logs/desktop.log"
OUT="$LOG_DIR/run-e-record.log"
RESULTS="$LOG_DIR/results.tsv"

# shellcheck source=activate-repo-venv.sh
source "$SCRIPT_DIR/activate-repo-venv.sh"
source "$SCRIPT_DIR/mem_sample.sh"
bash "$SCRIPT_DIR/setup-memory-homes.sh" >/dev/null

mkdir -p "$LOG_DIR"
: > "$OUT"

find_dashboard_pid() {
  pgrep -f "hermes_cli\.main.*dashboard" | head -1 || true
}

find_electron_pid() {
  pgrep -f "node_modules/electron/dist/electron \." | head -1 || true
}

cleanup() {
  pkill -f "concurrently.*dev:renderer" 2>/dev/null || true
  pkill -f "npm run dev:renderer" 2>/dev/null || true
  pkill -f "npm run dev:electron" 2>/dev/null || true
  pkill -f "vite --host 127.0.0.1 --port 5174" 2>/dev/null || true
  pkill -f "node_modules/electron/dist/electron \." 2>/dev/null || true
  pkill -f "hermes_cli\.main.*dashboard" 2>/dev/null || true
  sleep 2
}
trap cleanup EXIT

cleanup

rm -f "$DESKTOP_LOG"
cd "$REPO/apps/desktop"
HERMES_HOME="$TEST_HOME" \
  HERMES_DESKTOP_HERMES_ROOT="$REPO" \
  HERMES_DESKTOP_WEB_DIST="$TEST_HOME/web_dist" \
  npm run dev >>"$OUT" 2>&1 &
NPM_PID=$!
echo "npm run dev pid=$NPM_PID" | tee -a "$OUT"

DASH_PID=""
for i in $(seq 1 120); do
  DASH_PID=$(find_dashboard_pid)
  if [[ -n "$DASH_PID" ]]; then
    if grep -q "HERMES_DASHBOARD_READY" "$DESKTOP_LOG" 2>/dev/null || \
       grep -q "HERMES_DASHBOARD_READY" "$OUT" 2>/dev/null; then
      echo "dashboard ready after ${i}x2s dash=$DASH_PID" | tee -a "$OUT"
      break
    fi
  fi
  sleep 2
done

DASH_PID=$(find_dashboard_pid)
ELECTRON_PID=$(find_electron_pid)

if [[ -z "$DASH_PID" ]]; then
  echo "ERROR: dashboard never started" | tee -a "$OUT"
  tail -30 "$OUT"
  tail -30 "$DESKTOP_LOG" 2>/dev/null || true
  exit 1
fi

echo "Waiting 45s for boot + MCP discovery..." | tee -a "$OUT"
sleep 45

{
  echo ""
  echo "=== RUN E: Electron dev memory record $(date -Is) ==="
  mem_sample "E_dashboard" "$DASH_PID"
  if [[ -n "$ELECTRON_PID" ]]; then
    mem_sample "E_electron_main" "$ELECTRON_PID"
  fi
  echo "--- pgrep playwright ---"
  pgrep -lf playwright || echo "(none)"
  echo "--- pgrep slash_worker ---"
  pgrep -lf slash_worker || echo "(none)"
  process_tree "$DASH_PID"
} | tee -a "$OUT" "$LOG_DIR/run-e-sample.log"

DASH_KB=$(dashboard_rss_kb "$DASH_PID")
CHILD_KB=$(children_rss_kb "$DASH_PID")
ELEC_KB=0
[[ -n "$ELECTRON_PID" ]] && ELEC_KB=$(dashboard_rss_kb "$ELECTRON_PID")

echo -e "E\tdesktop_idle\t${DASH_KB}\t${CHILD_KB}\t591\telectron npm run dev" >> "$RESULTS"
echo "RECORD E dashboard=${DASH_KB}KB children=${CHILD_KB}KB electron=${ELEC_KB}KB total_tree=$((DASH_KB + CHILD_KB))KB" | tee -a "$OUT"

echo "Done. Log: $OUT"
