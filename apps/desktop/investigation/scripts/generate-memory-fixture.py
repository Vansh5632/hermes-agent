#!/usr/bin/env python3
"""Generate synthetic state.db fixtures for dashboard memory investigation."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[4]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))


def _tool_calls_blob() -> str:
    payload = [
        {
            "id": f"call_{i}",
            "type": "function",
            "function": {
                "name": "terminal",
                "arguments": json.dumps({"command": "echo memory-fixture", "background": False}),
            },
        }
        for i in range(3)
    ]
    return json.dumps(payload)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", required=True, help="HERMES_HOME directory")
    parser.add_argument("--sessions", type=int, default=595)
    parser.add_argument("--messages", type=int, default=39_126)
    parser.add_argument("--body-chars", type=int, default=2500)
    parser.add_argument("--target-mb", type=int, default=469, help="Warn if smaller (0 = skip check)")
    parser.add_argument("--force", action="store_true", help="Remove existing state.db first")
    args = parser.parse_args()

    home = Path(args.home).expanduser().resolve()
    home.mkdir(parents=True, exist_ok=True)
    db_path = home / "state.db"
    if args.force and db_path.exists():
        db_path.unlink()

    os.environ["HERMES_HOME"] = str(home)

    from hermes_state import SessionDB

    if args.sessions <= 0:
        print("sessions must be positive", file=sys.stderr)
        return 1
    msgs_per = max(1, args.messages // args.sessions)
    body = "x" * max(1, args.body_chars)
    tool_blob = _tool_calls_blob()

    db = SessionDB()
    t0 = time.time()
    for i in range(args.sessions):
        sid = f"memtest-{i:04d}-{uuid.uuid4().hex[:8]}"
        db.create_session(sid, "cli")
        db.set_session_title(sid, f"Mem test {i}")
        for j in range(msgs_per):
            role = "user" if j % 2 == 0 else "assistant"
            db.append_message(
                sid,
                role,
                f"{body} turn {j}",
                tool_calls=tool_blob if role == "assistant" else None,
            )
        db.end_session(sid, "ended")
        if (i + 1) % 50 == 0 or i + 1 == args.sessions:
            print(f"  {i + 1}/{args.sessions} sessions ({time.time() - t0:.1f}s)", flush=True)

    total_sessions = db.session_count()
    total_messages = db.message_count()
    db.close()

    size_mb = db_path.stat().st_size / (1024 * 1024)
    elapsed = time.time() - t0
    print(f"Done in {elapsed:.1f}s")
    print(f"  sessions: {total_sessions}")
    print(f"  messages: {total_messages}")
    print(f"  state.db: {size_mb:.1f} MB ({db_path})")

    if args.target_mb > 0 and size_mb < args.target_mb * 0.85:
        suggested = int(args.body_chars * (args.target_mb / max(size_mb, 1)))
        print(
            f"  NOTE: below target ~{args.target_mb} MB — retry with "
            f"--body-chars {suggested} (or higher)",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
