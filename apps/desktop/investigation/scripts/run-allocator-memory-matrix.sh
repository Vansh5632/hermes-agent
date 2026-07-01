#!/usr/bin/env bash
# Linux allocator A/B: system vs mimalloc preload, trim on vs off.
#
# Simulates Electron's Python spawn env (LD_PRELOAD + MIMALLOC_*) on hermes dashboard
# so you can measure allocator impact without launching Electron.
#
# Prerequisites:
#   sudo apt install libmimalloc2.0
#   cd apps/desktop && node scripts/stage-native-deps.cjs
#   bash investigation/scripts/setup-memory-homes.sh
#   large fixture in /tmp/hermes-mem-test (see DASHBOARD_MEMORY_NOTES.md)
#
# Usage:
#   bash apps/desktop/investigation/scripts/run-allocator-memory-matrix.sh
#   IDLE_SEC=90 bash .../run-allocator-memory-matrix.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../../../.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP="$REPO/apps/desktop"

source "$REPO/venv/bin/activate"
source "$SCRIPT_DIR/mem_sample.sh"

TEST_HOME="${HERMES_MEM_TEST_HOME:-/tmp/hermes-mem-test}"
WEB_DIST="$TEST_HOME/web_dist"
LOG_DIR="$TEST_HOME/logs/allocator"
RESULTS="$LOG_DIR/results.tsv"
PORT="${DASHBOARD_MEM_PORT:-9120}"
IDLE_SEC="${IDLE_SEC:-60}"
API_IDLE_SEC="${API_IDLE_SEC:-60}"

mkdir -p "$LOG_DIR" "$WEB_DIST/assets"
[[ -f "$WEB_DIST/index.html" ]] || echo '<!DOCTYPE html><html><body>stub</body></html>' > "$WEB_DIST/index.html"

export HERMES_DASHBOARD_SESSION_TOKEN="${HERMES_DASHBOARD_SESSION_TOKEN:-$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')}"

# Resolve staged mimalloc (Electron uses linux-x64 / darwin-arm64, not uname -m)
MIMALLOC_LIB=$(node -e "
const path = require('node:path');
const { resolveMimallocLibPath } = require('${DESKTOP}/electron/allocator-env.cjs');
console.log(resolveMimallocLibPath({ appRoot: '${DESKTOP}', platform: 'linux', arch: process.env.npm_config_arch || process.arch }) || '');
")
if [[ -z "$MIMALLOC_LIB" || ! -f "$MIMALLOC_LIB" ]]; then
  echo "Staging mimalloc (install libmimalloc2.0 if this fails)..." >&2
  (cd "$DESKTOP" && node scripts/stage-native-deps.cjs) || true
  MIMALLOC_LIB=$(node -e "
const { resolveMimallocLibPath } = require('${DESKTOP}/electron/allocator-env.cjs');
console.log(resolveMimallocLibPath({ appRoot: '${DESKTOP}', platform: 'linux', arch: process.env.npm_config_arch || process.arch }) || '');
")
fi

write_memory_config() {
  local allocator="$1" trim="$2"
  python3 <<PY
import yaml
from pathlib import Path
home = Path("$TEST_HOME")
trim_val = $( [[ "$trim" == "true" ]] && echo True || echo False )
cfg = yaml.safe_load((home / "config.yaml").read_text())
cfg.setdefault("dashboard", {})["memory"] = {
    "allocator": "$allocator",
    "lazy_mcp": True,
    "trim": trim_val,
    "trim_idle_seconds": 60,
    "trim_cooldown_seconds": 120,
}
(home / "config.yaml").write_text(yaml.dump(cfg, default_flow_style=False, sort_keys=False))
print("config allocator=%s trim=%s" % ("$allocator", trim_val))
PY
}

stop_dashboard() {
  local pid="${1:-}"
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  pkill -f "hermes.*dashboard.*--port $PORT" 2>/dev/null || true
  sleep 2
}

wait_ready() {
  local logfile="$1" timeout="${2:-120}"
  local i=0
  while [[ $i -lt $timeout ]]; do
    if grep -q 'HERMES_DASHBOARD_READY' "$logfile" 2>/dev/null; then
      return 0
    fi
    if grep -qE 'Traceback|RuntimeError|SystemExit' "$logfile" 2>/dev/null; then
      tail -20 "$logfile"
      return 1
    fi
    sleep 1
    i=$((i + 1))
  done
  tail -20 "$logfile"
  return 1
}

mimalloc_loaded() {
  local pid="$1"
  grep -q mimalloc "/proc/$pid/maps" 2>/dev/null
}

record_line() {
  local variant="$1" checkpoint="$2" pid="$3" notes="${4:-}"
  local rss_kb child_kb maps_note
  rss_kb=$(dashboard_rss_kb "$pid")
  child_kb=$(children_rss_kb "$pid")
  if mimalloc_loaded "$pid"; then
    maps_note="mimalloc=yes"
  else
    maps_note="mimalloc=no"
  fi
  echo -e "${variant}\t${checkpoint}\t${rss_kb}\t${child_kb}\t${maps_note}\t${notes}" >> "$RESULTS"
  echo "RECORD ${variant} ${checkpoint} rss=${rss_kb}KB children=${child_kb}KB ${maps_note} ${notes}" | tee -a "$LOG_DIR/matrix.log"
}

run_variant() {
  local variant="$1" allocator="$2" trim="$3" use_preload="$4"
  local logfile="$LOG_DIR/run-${variant}.log"

  write_memory_config "$allocator" "$trim"
  stop_dashboard ""

  export HERMES_HOME="$TEST_HOME" HERMES_DESKTOP=1 HERMES_WEB_DIST="$WEB_DIST"
  export HERMES_DASHBOARD_SESSION_TOKEN
  unset LD_PRELOAD MIMALLOC_PURGE_DELAY MIMALLOC_ARENA_EAGER_COMMIT

  if [[ "$use_preload" == "1" ]]; then
    export LD_PRELOAD="$MIMALLOC_LIB"
    export MIMALLOC_PURGE_DELAY=0
    export MIMALLOC_ARENA_EAGER_COMMIT=0
  fi

  : > "$logfile"
  echo "=== VARIANT $variant allocator=$allocator trim=$trim preload=$use_preload ===" | tee -a "$LOG_DIR/matrix.log"
  hermes dashboard --no-open --host 127.0.0.1 --port "$PORT" --skip-build >>"$logfile" 2>&1 &
  local pid=$!

  wait_ready "$logfile"
  sleep 3
  record_line "$variant" T0_ready "$pid" "post-startup"

  sleep "$IDLE_SEC"
  record_line "$variant" T1_idle "$pid" "idle ${IDLE_SEC}s"

  curl -sf -H "X-Hermes-Session-Token: $HERMES_DASHBOARD_SESSION_TOKEN" \
    "http://127.0.0.1:${PORT}/api/profiles/sessions?limit=50&offset=0&min_messages=0&archived=exclude&order=recent&profile=all&exclude_sources=cron" >/dev/null
  curl -sf -H "X-Hermes-Session-Token: $HERMES_DASHBOARD_SESSION_TOKEN" \
    "http://127.0.0.1:${PORT}/api/sessions/stats" >/dev/null
  record_line "$variant" T2_after_api "$pid" "sessions+stats API"

  sleep "$API_IDLE_SEC"
  record_line "$variant" T3_post_api_idle "$pid" "idle ${API_IDLE_SEC}s after API (trim window)"

  stop_dashboard "$pid"
}

: > "$RESULTS"
echo -e "variant\tcheckpoint\trss_kb\tchildren_kb\tmimalloc_maps\tnotes" >> "$RESULTS"

# A: production control (system allocator, no trim)
run_variant A_system_notrim system false 0

# B: trim only (Linux glibc malloc_trim path)
run_variant B_system_trim system true 0

# C: mimalloc only (Electron preload path, trim disabled in config)
run_variant C_mimalloc_notrim mimalloc false 1

# D: full desktop defaults (mimalloc + trim)
run_variant D_mimalloc_trim auto true 1

echo ""
echo "=== Allocator results: $RESULTS ==="
column -t -s $'\t' "$RESULTS" | tee "$LOG_DIR/results-table.txt"

python3 <<'PY'
from pathlib import Path

rows = []
for line in Path("/tmp/hermes-mem-test/logs/allocator/results.tsv").read_text().splitlines()[1:]:
    if not line.strip():
        continue
    v, ck, rss, ch, mi, *rest = line.split("\t")
    rows.append((v, ck, int(rss), int(ch), mi, rest[0] if rest else ""))

by = {}
for v, ck, rss, ch, mi, notes in rows:
    by.setdefault(v, {})[ck] = (rss, ch, mi, notes)

def mb(k):
    return k / 1024

print("\n=== Summary (MB) ===")
for v in sorted(by):
    print(f"{v}:")
    for ck in ("T0_ready", "T1_idle", "T2_after_api", "T3_post_api_idle"):
        if ck in by[v]:
            r, c, mi, n = by[v][ck]
            print(f"  {ck}: rss={mb(r):.1f} child={mb(c):.1f} [{mi}] {n}")

def delta(v, c1, c2):
    if c1 in by.get(v, {}) and c2 in by.get(v, {}):
        return by[v][c2][0] - by[v][c1][0]

print("\n=== Key deltas (dashboard RSS, KB) ===")
pairs = [
    ("T2_after_api → T3 (reclaim after API idle)", "T2_after_api", "T3_post_api_idle"),
    ("T0 → T1 (startup → idle)", "T0_ready", "T1_idle"),
]
for label, a, b in pairs:
    print(label)
    for v in sorted(by):
        d = delta(v, a, b)
        if d is not None:
            print(f"  {v}: {d:+d} KB ({d/1024:+.2f} MB)")

if "B_system_trim" in by and "A_system_notrim" in by:
    d = delta("B_system_trim", "T2_after_api", "T3_post_api_idle")
    d0 = delta("A_system_notrim", "T2_after_api", "T3_post_api_idle")
    if d is not None and d0 is not None:
        print(f"\ntrim effect (T3-T2): trim={d/1024:.2f} MB vs notrim={d0/1024:.2f} MB (delta of deltas={(d-d0)/1024:+.2f} MB)")

if "C_mimalloc_notrim" in by and "A_system_notrim" in by:
    for ck in ("T1_idle", "T3_post_api_idle"):
        if ck in by["C_mimalloc_notrim"] and ck in by["A_system_notrim"]:
            d = by["C_mimalloc_notrim"][ck][0] - by["A_system_notrim"][ck][0]
            print(f"mimalloc vs system @ {ck}: {d/1024:+.2f} MB")
PY

echo "Full log: $LOG_DIR/matrix.log"
