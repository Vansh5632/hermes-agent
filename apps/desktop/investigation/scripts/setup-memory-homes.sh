#!/usr/bin/env bash
# Setup isolated HERMES_HOME dirs for dashboard memory investigation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=activate-repo-venv.sh
source "$SCRIPT_DIR/activate-repo-venv.sh"

TEST_HOME="/tmp/hermes-mem-test"
CONTROL_HOME="/tmp/hermes-mem-control"

mkdir -p "$TEST_HOME/web_dist/assets" "$CONTROL_HOME"
echo '<!DOCTYPE html><html><body>stub</body></html>' > "$TEST_HOME/web_dist/index.html"
echo '/* stub */' > "$TEST_HOME/web_dist/assets/stub.css"

python3 <<'PY'
import copy
import os
from pathlib import Path

import yaml

from hermes_cli.config import DEFAULT_CONFIG

baseline = os.environ.get("MEMORY_BASELINE", "auto")
if baseline == "auto":
    try:
        import tools.mcp_schema_cache  # noqa: F401
        baseline = "0"
    except ImportError:
        baseline = "1"

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
    print("wrote", home, "config.yaml", f"(baseline={baseline})")
PY

echo "Homes ready: $CONTROL_HOME (no MCP), $TEST_HOME (Playwright MCP)"
echo "Web dist stub: $TEST_HOME/web_dist"
