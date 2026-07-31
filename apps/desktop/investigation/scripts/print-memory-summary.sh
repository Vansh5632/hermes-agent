#!/usr/bin/env bash
# Print dashboard memory investigation results as a terminal / GITHUB_STEP_SUMMARY table.
set -euo pipefail

RESULTS="${1:-/tmp/hermes-mem-test/logs/results.tsv}"

if [[ ! -f "$RESULTS" ]]; then
  echo "No results file: $RESULTS" >&2
  echo "Run: cd apps/desktop && npm run investigate:dashboard-memory" >&2
  exit 1
fi

python3 - "$RESULTS" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text().splitlines()
if len(lines) < 2:
    print("Results file is empty.")
    sys.exit(0)

rows = []
seen = set()
for line in lines[1:]:
    if not line.strip():
        continue
    parts = line.split("\t")
    run, ckpt = parts[0], parts[1]
    key = (run, ckpt)
    if key in seen:
        continue
    seen.add(key)
    dash, child = int(parts[2]), int(parts[3])
    db = int(parts[4])
    notes = parts[5] if len(parts) > 5 else ""
    rows.append((run, ckpt, dash, child, db, notes))


def mb(kb: int) -> float:
    return kb / 1024


print("## Dashboard memory results\n")
print("| Run | Checkpoint | Dashboard (MB) | Children (MB) | DB (MB) | Notes |")
print("|-----|------------|------------------:|----------------:|--------:|-------|")
for run, ckpt, dash, child, db, notes in rows:
    print(f"| {run} | {ckpt} | {mb(dash):.1f} | {mb(child):.1f} | {db} | {notes} |")

by = {}
for r in rows:
    by.setdefault(r[0], {})[r[1]] = r

print("\n### Deltas (MB)\n")
a = by.get("A", {}).get("T1")
b = by.get("B", {}).get("T1")
c = by.get("C", {}).get("T2")
d = by.get("D", {}).get("session_create")
d2 = by.get("D2", {}).get("T1")
e = by.get("E", {}).get("desktop_idle")

if a and b:
    print(f"- **B − A (idle):** dashboard {mb(b[2]-a[2]):+.1f}, children {mb(b[3]-a[3]):+.1f}")
if b and c:
    print(f"- **C − B (session API):** dashboard {mb(c[2]-b[2]):+.1f}")
if b and d2:
    print(f"- **D2 − B (MCP off):** dashboard {mb(d2[2]-b[2]):+.1f}, children {mb(d2[3]-b[3]):+.1f}")
if c and d:
    print(f"- **D − C (2× create):** dashboard {mb(d[2]-c[2]):+.1f}, children {mb(d[3]-c[3]):+.1f}")
    print(f"- **D total tree:** {mb(d[2]+d[3]):.1f}")
if e:
    print(f"- **E (Electron idle):** dashboard {mb(e[2]):.1f}, children {mb(e[3]):.1f}, tree {mb(e[2]+e[3]):.1f}")

print(f"\nSource: `{path}`")
PY
