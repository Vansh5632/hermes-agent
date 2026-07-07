# Dashboard Memory Investigation Notes

Investigation of high RSS for the Hermes Desktop / `hermes dashboard` Python backend with large session stores.

## Quick start (Linux, synthetic DB, no Mac required)

From repo root:

```bash
source venv/bin/activate
npm install   # once, from repo root (Electron workspace)

# 1. Isolated homes + Playwright MCP config
bash apps/desktop/investigation/scripts/setup-memory-homes.sh

# 2. Control fixture (~0.3 MB)
python3 apps/desktop/investigation/scripts/generate-memory-fixture.py \
  --home /tmp/hermes-mem-control --sessions 5 --messages 50 --body-chars 400 \
  --target-mb 0 --force

# 3. Large fixture (~590 MB with default body size)
python3 apps/desktop/investigation/scripts/generate-memory-fixture.py \
  --home /tmp/hermes-mem-test --sessions 595 --messages 39126 --body-chars 2500 --force

# 4. Full measurement matrix (~5 min)
cd apps/desktop && npm run investigate:dashboard-memory
```

Logs: `/tmp/hermes-mem-test/logs/` (`results.tsv`, `matrix.log`).

### Capture everything from the terminal

Pipe the matrix run through `tee` so stdout and log file stay in sync:

```bash
cd apps/desktop
npm run investigate:dashboard-memory 2>&1 | tee ~/dashboard-mem-$(date +%Y%m%d-%H%M).log
```

After any run, print a markdown table from `results.tsv`:

```bash
npm run investigate:dashboard-memory:summary
# or: bash investigation/scripts/print-memory-summary.sh /tmp/hermes-mem-test/logs/results.tsv
```

Key lines to grep from the log:

```bash
grep '^RECORD' ~/dashboard-mem-*.log          # one line per checkpoint
grep -A20 'Summary (MB)' ~/dashboard-mem-*.log # delta block at end of matrix
```

Raw TSV (paste into a spreadsheet):

```bash
column -t -s $'\t' /tmp/hermes-mem-test/logs/results.tsv
```

### GitHub Actions (manual workflow)

Workflow: [`.github/workflows/dashboard-memory-investigation.yml`](../../../.github/workflows/dashboard-memory-investigation.yml)

Trigger from the repo **Actions** tab → **Dashboard Memory Investigation** → **Run workflow**:

| Input | Purpose |
|-------|---------|
| `fixture_profile: full` | 595 sessions, ~590 MB DB (macOS-parity) |
| `fixture_profile: quick` | 50 sessions — validates the pipeline in ~5 min |
| `include_electron` | Run E under `xvfb-run` on ubuntu-latest |
| `mcp_wait_sec` | Wait for Playwright MCP child (default 90) |

Outputs:

- **Job log** — `RECORD …` lines + Python summary (same as local)
- **Step Summary** — markdown table on the run page
- **Artifact** — `/tmp/hermes-mem-test/logs/` (`results.tsv`, `matrix.log`, `run-e-*.log`)

**What CI can vs cannot do:**

| | Linux GHA | macOS GHA (not wired yet) |
|--|-----------|---------------------------|
| Runs A–D2 (backend only) | Yes | Yes |
| Run E (Electron + xvfb) | Yes (optional input) | Native display, no xvfb |
| ~1 GB dashboard-only RSS | Not observed (~150 MB) | Needs `vmmap` job to confirm pymalloc |

To add macOS `vmmap`, duplicate the backend job with `runs-on: macos-latest` and append `vmmap --summary $PID` in `mem_sample.sh` when `uname` is Darwin.

---

## Prerequisites (one-time)

| Requirement | Check | Install |
|-------------|-------|---------|
| Python 3.11 + venv | `python3.11 --version` | `sudo apt install python3.11 python3.11-venv` |
| Hermes editable | `hermes --version` | `pip install -e .` from repo root |
| Node 20+ / 22+ | `node -v` | [nodejs.org](https://nodejs.org) or nvm |
| npm workspace | `npm install` at repo root | pulls Electron (~hundreds of MB first time) |
| sqlite3, pmap | `sqlite3 --version`, `which pmap` | `sudo apt install sqlite3 procps` |
| websockets | `python3 -c "import websockets"` | `pip install websockets` |
| Playwright MCP | `npx -y @playwright/mcp@latest --help` | auto-download on first MCP discovery (network) |

**Never use real `~/.hermes`** for this investigation — fixtures live under `/tmp/hermes-mem-test` and `/tmp/hermes-mem-control`.

---

## What you can vs cannot verify without macOS

| Signal | Linux (this repro) | macOS only |
|--------|-------------------|------------|
| ~469+ MB `state.db` + dual FTS | Yes (synthetic) | No |
| Playwright MCP child | Yes (~160–250 MB observed) | No |
| 2× `slash_worker` children | Yes (~45 MB each) | No |
| Process tree ~400–500 MB+ | Yes | No |
| Dashboard Python idle ~1 GB alone | **Not observed** (~111–122 MB idle) | Reported |
| `vmmap` empty `MALLOC_LARGE` (~306 MB) | **No** — use `pmap`/RSS | Yes |

---

## macOS-parity run results (2026-06-30, Linux)

**Fixture:** 595 sessions, 38,675 messages, **591 MB** `state.db` (`--body-chars 2500` + indexed `tool_calls`).

**Config:** Playwright MCP enabled in `/tmp/hermes-mem-test/config.yaml`:

```yaml
mcp_servers:
  playwright:
    command: npx
    args: ["-y", "@playwright/mcp@latest"]
    enabled: true
```

### Results table

| Run | Checkpoint | Dashboard RSS (MB) | Children RSS (MB) | state.db (MB) | Notes |
|-----|------------|--------------------:|------------------:|--------------:|-------|
| A | T1 idle | 110.8 | 0.0 | 1 | control, no MCP |
| B | T1 idle | 113.6 | **250.1** | 591 | large DB + MCP (90s wait) |
| C | T2 `/api/profiles/sessions` | 118.7 | 250.1 | 591 | 50 sessions, total=595 |
| C | T3 `/api/sessions/stats` | 119.1 | 250.1 | 591 | |
| C | T4 idle after API | 119.1 | 160.0 | 591 | MCP child shrank |
| D | 2× `session.create` | **173.2** | **249.0** | 591 | 2× slash_worker + MCP |
| D2 | T1 MCP disabled | 111.0 | 0.0 | 591 | same large DB, no MCP |
| **E** | Electron `npm run dev` idle | **150.2** | **173.4** | 591 | + Electron main ~208 MB; no slash_workers |

### Key deltas

| Comparison | Dashboard | Children | Interpretation |
|------------|----------:|-----------:|----------------|
| **B − A** (idle) | +2.7 MB | +250.1 MB | **Large DB does not raise idle dashboard RSS**; Playwright MCP dominates |
| **C − B** (session API) | +5.1 MB | 0 MB | Desktop boot session list adds modest retained heap |
| **D2 − B** (MCP off) | −2.6 MB | −250.1 MB | Confirms MCP child cost |
| **D − C** (2× chat) | +54.5 MB | −1.1 MB | Agent build in dashboard; 2× slash_worker ~90 MB in tree |
| **D total (dash + children)** | | **422.2 MB** | Approaches half of reported ~1 GB |
| **E total (dash + children + electron main)** | | **~531 MB** | Desktop dev stack; still below ~1 GB macOS report |

### Run E detail (2026-06-30, automated)

Electron dev with `HERMES_HOME=/tmp/hermes-mem-test`, `HERMES_DESKTOP_WEB_DIST=/tmp/hermes-mem-test/web_dist` (web dist stub — repo has no built `hermes_cli/web_dist`):

| Process | RSS (MB) | Notes |
|---------|----------:|-------|
| Dashboard Python | 150.2 | `-m hermes_cli.main dashboard` |
| Playwright MCP child | 173.4 | Same npx child as run B |
| Electron main | 212.8 | Chromium shell + renderer helpers |
| **Combined (dash + MCP + electron main)** | **~536** | No chat sessions → no slash_workers |

Script: `/tmp/hermes-mem-test/run-electron-record.sh` (or copy from investigation). Logs: `/tmp/hermes-mem-test/logs/run-e-record.log`, `run-e-sample.log`.

### SQLite (idle, large DB)

```
PRAGMA cache_size → -2000 (~2 MB)
PRAGMA mmap_size → 0
PRAGMA journal_mode → wal
```

591 MB on disk; dashboard RSS ~114–122 MB idle — file is **not** fully mapped into RAM.

---

## Reproduction verdict

**Partial behavioral reproduction on Linux.**

- With **591 MB DB + Playwright MCP + 2 chat sessions**, total process tree reaches **~422 MB** (dashboard 173 MB + children 249 MB).
- **Playwright MCP alone adds ~250 MB** as a separate child (larger than the ~108 MB in the original macOS report).
- **Idle dashboard Python stays ~111–122 MB** even with a 591 MB DB — same class of result as the earlier 74 MB / 111 MB run.
- The original **~1 GB dashboard-only RSS** on macOS is **not reproduced** on Linux; likely needs macOS pymalloc/`MALLOC_LARGE` behavior or additional startup paths.

**Run E (Electron `npm run dev`):** automated on Linux with display. Requires web dist stub (setup script creates one under `$HERMES_HOME/web_dist`) because the repo may not have a built dashboard bundle:

```bash
bash apps/desktop/investigation/scripts/setup-memory-homes.sh
bash /tmp/hermes-mem-test/run-electron-record.sh
# Or manually:
cd apps/desktop
HERMES_HOME=/tmp/hermes-mem-test \
  HERMES_DESKTOP_HERMES_ROOT=$PWD/../.. \
  HERMES_DESKTOP_WEB_DIST=/tmp/hermes-mem-test/web_dist \
  npm run dev
```

PID detection: `pgrep -f 'hermes_cli.main.*dashboard'` (not `hermes dashboard`).

---

## Scripts

| Script | Purpose |
|--------|---------|
| [`scripts/setup-memory-homes.sh`](scripts/setup-memory-homes.sh) | Create `/tmp/hermes-mem-*` + configs + web dist stub |
| [`scripts/generate-memory-fixture.py`](scripts/generate-memory-fixture.py) | Synthetic `state.db` with tunable `--body-chars` |
| [`scripts/mem_sample.sh`](scripts/mem_sample.sh) | `mem_sample`, `process_tree`, `sqlite_pragma` |
| [`scripts/run-dashboard-memory-matrix.sh`](scripts/run-dashboard-memory-matrix.sh) | Automated runs A–D2 |
| [`scripts/run-electron-memory.sh`](scripts/run-electron-memory.sh) | Run E: Electron dev + memory sample |
| [`scripts/print-memory-summary.sh`](scripts/print-memory-summary.sh) | Markdown table from `results.tsv` |

Or from `apps/desktop`: `npm run investigate:dashboard-memory`

---

## Prior Linux run (smaller fixture, no MCP)

Earlier run with 74 MB DB and empty MCP: idle ~111 MB, API +5 MB, one slash_worker → ~251 MB total. See git history of this file.

---

## Optional: macOS `vmmap` without a local Mac

Use GitHub Actions `macos-latest` (manual workflow) or cloud Mac rental to run the same scripts and capture `vmmap --summary $PID` if product needs confirmation of empty `MALLOC_LARGE`.

---

## Tuning fixture size

Target ~450–470 MB on disk:

```bash
python3 apps/desktop/investigation/scripts/generate-memory-fixture.py \
  --home /tmp/hermes-mem-test --body-chars 2500 --force
ls -lh /tmp/hermes-mem-test/state.db
```

If too small/large, adjust `--body-chars` (script suggests a value when below `--target-mb`).
