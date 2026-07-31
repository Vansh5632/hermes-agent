#!/usr/bin/env bash
# RSS / memory sampling for dashboard memory investigation (Linux + macOS).

mem_sample() {
  local label="$1" pid="$2"
  echo "=== $label pid=$pid $(date -Is) ==="
  ps -o pid,rss,vsz,%mem,etime,command -p "$pid" 2>/dev/null || ps -o pid,rss,vsz,%mem,etime,command -p "$pid" 2>/dev/null || { echo "process $pid gone"; return 1; }

  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "--- vmmap summary (macOS) ---"
    vmmap --summary "$pid" 2>/dev/null | grep -E '^(Physical footprint|MALLOC|stack|VM_ALLOCATE)' || vmmap --summary "$pid" 2>/dev/null | tail -15 || echo "(vmmap unavailable)"
  else
    awk '/VmRSS|VmHWM|VmData|VmSize/ {print}' "/proc/$pid/status" 2>/dev/null
    echo "--- pmap summary ---"
    pmap -x "$pid" 2>/dev/null | tail -1 || echo "(pmap unavailable)"
  fi

  echo "--- children ---"
  local child_rss=0
  if pgrep -P "$pid" >/dev/null 2>&1; then
    while read -r c; do
      ps -o pid,rss,command -p "$c" 2>/dev/null
      local rss
      rss=$(ps -o rss= -p "$c" 2>/dev/null | tr -d ' ')
      child_rss=$((child_rss + ${rss:-0}))
    done < <(pgrep -P "$pid")
  else
    echo "(none)"
  fi
  echo "--- child_rss_total_kb=$child_rss (~$((child_rss / 1024)) MB) ---"
  echo
}

dashboard_rss_kb() {
  ps -o rss= -p "$1" 2>/dev/null | tr -d ' '
}

children_rss_kb() {
  local pid="$1" total=0 c rss
  for c in $(pgrep -P "$pid" 2>/dev/null); do
    rss=$(ps -o rss= -p "$c" 2>/dev/null | tr -d ' ')
    total=$((total + ${rss:-0}))
  done
  echo "$total"
}

process_tree() {
  local pid="$1"
  if command -v pstree >/dev/null 2>&1; then
    pstree -p "$pid"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    ps -g "$(ps -o pgid= -p "$pid" | tr -d ' ')" -o pid,rss,command 2>/dev/null
  else
    ps --forest -g "$(ps -o sid= -p "$pid" | tr -d ' ')" -o pid,rss,cmd 2>/dev/null
  fi
}

sqlite_pragma() {
  local home="$1"
  sqlite3 "$home/state.db" "
    PRAGMA cache_size;
    PRAGMA mmap_size;
    PRAGMA journal_mode;
    PRAGMA page_count;
    PRAGMA page_size;
  "
}

export -f mem_sample dashboard_rss_kb children_rss_kb process_tree sqlite_pragma
