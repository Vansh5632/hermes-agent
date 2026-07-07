#!/usr/bin/env bash
# Automated dashboard memory matrix (Linux, synthetic DB).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=activate-repo-venv.sh
source "$SCRIPT_DIR/activate-repo-venv.sh"
source "$SCRIPT_DIR/mem_sample.sh"

TEST_HOME="/tmp/hermes-mem-test"
CONTROL_HOME="/tmp/hermes-mem-control"
WEB_DIST="$TEST_HOME/web_dist"
LOG_DIR="$TEST_HOME/logs"
RESULTS="$LOG_DIR/results.tsv"
PORT="${DASHBOARD_MEM_PORT:-9119}"
MCP_WAIT_SEC="${MCP_WAIT_SEC:-90}"
IDLE_SEC="${IDLE_SEC:-60}"

mkdir -p "$LOG_DIR" "$WEB_DIST/assets"
echo '<!DOCTYPE html><html><body>stub</body></html>' > "$WEB_DIST/index.html"
echo '/* stub */' > "$WEB_DIST/assets/stub.css"

if [[ "${MEMORY_BASELINE:-auto}" == "auto" ]]; then
  if python3 -c "import tools.mcp_schema_cache" 2>/dev/null; then
    export MEMORY_BASELINE=0
  else
    export MEMORY_BASELINE=1
  fi
fi

export HERMES_DASHBOARD_SESSION_TOKEN="${HERMES_DASHBOARD_SESSION_TOKEN:-$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')}"

: > "$RESULTS"
echo -e "run\tcheckpoint\tdashboard_rss_kb\tchildren_rss_kb\tstate_db_mb\tnotes" >> "$RESULTS"

record() {
  local run="$1" checkpoint="$2" pid="$3" home="$4" notes="${5:-}"
  local dash_kb child_kb db_mb
  dash_kb=$(dashboard_rss_kb "$pid")
  child_kb=$(children_rss_kb "$pid")
  db_mb=$(du -m "$home/state.db" 2>/dev/null | cut -f1 || echo 0)
  echo -e "${run}\t${checkpoint}\t${dash_kb}\t${child_kb}\t${db_mb}\t${notes}" >> "$RESULTS"
  echo "RECORD $run $checkpoint dash=${dash_kb}KB children=${child_kb}KB db=${db_mb}MB $notes" | tee -a "$LOG_DIR/matrix.log"
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

stop_dashboard() {
  local pid="${1:-}"
  if [[ -n "$pid" ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  pkill -f "hermes.*dashboard.*--port $PORT" 2>/dev/null || true
  pkill -f "hermes.*dashboard.*--port $PORT" 2>/dev/null || true
  sleep 2
}

start_dashboard() {
  local home="$1" logfile="$2"
  export HERMES_HOME="$home" HERMES_DESKTOP=1 HERMES_WEB_DIST="$WEB_DIST"
  export HERMES_DASHBOARD_SESSION_TOKEN
  : > "$logfile"
  hermes dashboard --no-open --host 127.0.0.1 --port "$PORT" --skip-build >>"$logfile" 2>&1 &
  echo $!
}

curl_sessions() {
  curl -sf -H "X-Hermes-Session-Token: $HERMES_DASHBOARD_SESSION_TOKEN" \
    "http://127.0.0.1:${PORT}/api/profiles/sessions?limit=50&offset=0&min_messages=0&archived=exclude&order=recent&profile=all&exclude_sources=cron"
}

curl_stats() {
  curl -sf -H "X-Hermes-Session-Token: $HERMES_DASHBOARD_SESSION_TOKEN" \
    "http://127.0.0.1:${PORT}/api/sessions/stats"
}

ws_session_create() {
  export DASH_PORT="$PORT" HERMES_DASHBOARD_SESSION_TOKEN
  python3 <<'PY'
import asyncio
import json
import os

import websockets

token = os.environ["HERMES_DASHBOARD_SESSION_TOKEN"]
port = os.environ.get("DASH_PORT", "9119")
uri = f"ws://127.0.0.1:{port}/api/ws?token={token}"


async def main() -> None:
    async with websockets.connect(uri, open_timeout=30) as ws:
        # Drain gateway.ready if present
        try:
            first = await asyncio.wait_for(ws.recv(), timeout=5)
            if '"method"' in first and '"event"' in first:
                pass
        except TimeoutError:
            pass
        req = {"jsonrpc": "2.0", "id": 1, "method": "session.create", "params": {}}
        await ws.send(json.dumps(req))
        resp = await asyncio.wait_for(ws.recv(), timeout=120)
        print(resp[:400])


asyncio.run(main())
PY
}

setup_configs() {
  python3 <<'PY'
import copy
import os
from pathlib import Path

import yaml

from hermes_cli.config import DEFAULT_CONFIG

baseline = os.environ.get("MEMORY_BASELINE", "1")
pw = {
    "command": "npx",
    "args": ["-y", "@playwright/mcp@latest", "--headless", "--isolated"],
    "enabled": True,
}
if baseline != "1":
    pw["lazy"] = True

for home, mcp in [
    ("/tmp/hermes-mem-control", {}),
    ("/tmp/hermes-mem-test", {"playwright": pw}),
]:
    Path(home).mkdir(parents=True, exist_ok=True)
    cfg = copy.deepcopy(DEFAULT_CONFIG)
    cfg["mcp_servers"] = mcp
    with open(f"{home}/config.yaml", "w", encoding="utf-8") as f:
        yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
    if mcp.get("playwright") and baseline != "1":
        os.environ["HERMES_HOME"] = str(home)
        from tools.mcp_schema_cache import config_fingerprint, write_cache_entry

        fp = config_fingerprint(mcp["playwright"])
        write_cache_entry(
            "playwright",
            fp,
            tools=[{
                "name": "browser_navigate",
                "description": "Navigate (investigation stub)",
                "inputSchema": {"type": "object", "properties": {}},
            }],
            utility_tools=[],
        )
    print("config", home, f"baseline={baseline}")
PY
}

echo "=== baseline ===" | tee "$LOG_DIR/matrix.log"
echo "MEMORY_BASELINE=$MEMORY_BASELINE" | tee -a "$LOG_DIR/matrix.log"
if command -v free >/dev/null 2>&1; then
  free -h | tee -a "$LOG_DIR/matrix.log"
elif [[ "$(uname -s)" == "Darwin" ]]; then
  vm_stat | head -8 | tee -a "$LOG_DIR/matrix.log"
fi
setup_configs

stop_dashboard ""

# --- Run A: control ---
echo "=== RUN A: control ===" | tee -a "$LOG_DIR/matrix.log"
LOG_A="$LOG_DIR/run-a.log"
PID=$(start_dashboard "$CONTROL_HOME" "$LOG_A")
wait_ready "$LOG_A"
mem_sample "A_T0" "$PID" | tee -a "$LOG_DIR/matrix.log"
record A T0 "$PID" "$CONTROL_HOME" "ready"
sleep "$IDLE_SEC"
mem_sample "A_T1" "$PID" | tee -a "$LOG_DIR/matrix.log"
record A T1 "$PID" "$CONTROL_HOME" "idle ${IDLE_SEC}s"
stop_dashboard "$PID"

# --- Run B: large + MCP idle ---
echo "=== RUN B: large + MCP ===" | tee -a "$LOG_DIR/matrix.log"
LOG_B="$LOG_DIR/run-b.log"
PID=$(start_dashboard "$TEST_HOME" "$LOG_B")
wait_ready "$LOG_B"
mem_sample "B_T0" "$PID" | tee -a "$LOG_DIR/matrix.log"
record B T0 "$PID" "$TEST_HOME" "ready"
echo "Waiting ${MCP_WAIT_SEC}s for MCP discovery..." | tee -a "$LOG_DIR/matrix.log"
sleep "$MCP_WAIT_SEC"
pgrep -lf playwright 2>/dev/null | tee -a "$LOG_DIR/matrix.log" || echo "no playwright child" | tee -a "$LOG_DIR/matrix.log"
if [[ "$MEMORY_BASELINE" == "1" ]]; then
  if pgrep -f '@playwright/mcp|playwright.*mcp' >/dev/null 2>&1; then
    echo "BASELINE: Playwright MCP child present at idle (expected on upstream)" | tee -a "$LOG_DIR/matrix.log"
  else
    echo "BASELINE: no Playwright MCP child at idle" | tee -a "$LOG_DIR/matrix.log"
  fi
elif pgrep -f '@playwright/mcp|playwright.*mcp' >/dev/null 2>&1; then
  echo "ASSERT FAIL: Playwright MCP child spawned at idle with lazy MCP + schema cache" | tee -a "$LOG_DIR/matrix.log"
  stop_dashboard "$PID"
  exit 1
else
  echo "ASSERT OK: no Playwright MCP child at idle (lazy MCP)" | tee -a "$LOG_DIR/matrix.log"
fi
mem_sample "B_T1" "$PID" | tee -a "$LOG_DIR/matrix.log"
record B T1 "$PID" "$TEST_HOME" "idle ${MCP_WAIT_SEC}s after MCP wait"

# --- Run C: session APIs (same dashboard) ---
OUT=$(curl_sessions | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'sessions={len(d[\"sessions\"])} total={d[\"total\"]}')")
echo "curl_sessions: $OUT" | tee -a "$LOG_DIR/matrix.log"
mem_sample "C_T2" "$PID" | tee -a "$LOG_DIR/matrix.log"
record C T2 "$PID" "$TEST_HOME" "$OUT"

OUT2=$(curl_stats | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'total={d.get(\"total\")} messages={d.get(\"messages\")}')")
echo "curl_stats: $OUT2" | tee -a "$LOG_DIR/matrix.log"
mem_sample "C_T3" "$PID" | tee -a "$LOG_DIR/matrix.log"
record C T3 "$PID" "$TEST_HOME" "$OUT2"

sleep "$IDLE_SEC"
mem_sample "C_T4" "$PID" | tee -a "$LOG_DIR/matrix.log"
record C T4 "$PID" "$TEST_HOME" "idle ${IDLE_SEC}s after API"

# --- Run D: 2x session.create ---
echo "=== RUN D: 2x session.create ===" | tee -a "$LOG_DIR/matrix.log"
ws_session_create 2>&1 | tee -a "$LOG_DIR/matrix.log" || true
sleep 8
ws_session_create 2>&1 | tee -a "$LOG_DIR/matrix.log" || true
sleep 10
mem_sample "D_after_2x_create" "$PID" | tee -a "$LOG_DIR/matrix.log"
record D session_create "$PID" "$TEST_HOME" "2x session.create"
process_tree "$PID" | tee -a "$LOG_DIR/matrix.log"
pgrep -lf slash_worker | tee -a "$LOG_DIR/matrix.log" || true
stop_dashboard "$PID"

# --- Run D2: MCP off isolation ---
echo "=== RUN D2: large MCP disabled ===" | tee -a "$LOG_DIR/matrix.log"
python3 <<'PY'
import copy
from pathlib import Path
import yaml
from hermes_cli.config import DEFAULT_CONFIG
home = Path("/tmp/hermes-mem-test")
cfg = yaml.safe_load((home / "config.yaml").read_text())
cfg["mcp_servers"] = {}
with open(home / "config.yaml", "w", encoding="utf-8") as f:
    yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
print("disabled mcp_servers")
PY
LOG_D2="$LOG_DIR/run-d2.log"
PID=$(start_dashboard "$TEST_HOME" "$LOG_D2")
wait_ready "$LOG_D2"
sleep "$IDLE_SEC"
mem_sample "D2_T1_no_mcp" "$PID" | tee -a "$LOG_DIR/matrix.log"
record D2 T1 "$PID" "$TEST_HOME" "mcp disabled"
stop_dashboard "$PID"

# restore MCP config
setup_configs

sqlite_pragma "$TEST_HOME" | tee -a "$LOG_DIR/matrix.log"

echo "=== RESULTS ===" | tee -a "$LOG_DIR/matrix.log"
cat "$RESULTS" | tee -a "$LOG_DIR/matrix.log"

python3 <<'PY'
from pathlib import Path

rows = []
seen = set()
for line in Path("/tmp/hermes-mem-test/logs/results.tsv").read_text().splitlines()[1:]:
    if not line.strip():
        continue
    parts = line.split("\t")
    run, ckpt = parts[0], parts[1]
    key = (run, ckpt)
    if key in seen:
        continue
    seen.add(key)
    dash, child, db = int(parts[2]), int(parts[3]), int(parts[4])
    notes = parts[5] if len(parts) > 5 else ""
    rows.append((run, ckpt, dash, child, db, notes))

by = {}
for r in rows:
    by.setdefault(r[0], {})[r[1]] = r

def mb(k):
    return k / 1024

print("\n=== Summary (MB) ===")
for run in sorted(by):
    print(f"Run {run}:")
    for ck, r in sorted(by[run].items()):
        print(f"  {ck}: dash={mb(r[2]):.1f} child={mb(r[3]):.1f} db={r[4]} | {r[5]}")

a = by.get("A", {}).get("T1")
b = by.get("B", {}).get("T1")
c = by.get("C", {}).get("T2")
d = by.get("D", {}).get("session_create")
d2 = by.get("D2", {}).get("T1")
print("\n=== Deltas ===")
if a and b:
    print(f"B-A idle: dash {mb(b[2]-a[2]):+.1f} MB, children {mb(b[3]-a[3]):+.1f} MB")
if b and c:
    print(f"C-B API:  dash {mb(c[2]-b[2]):+.1f} MB")
if b and d2:
    print(f"D2-B MCP off: dash {mb(d2[2]-b[2]):+.1f} MB, children {mb(d2[3]-b[3]):+.1f} MB")
if c and d:
    print(f"D-C 2x create: dash {mb(d[2]-c[2]):+.1f} MB, children {mb(d[3]-c[3]):+.1f} MB")
    print(f"D total tree: {mb(d[2]+d[3]):.1f} MB")
PY

echo "Logs: $LOG_DIR"
