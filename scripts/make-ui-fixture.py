#!/usr/bin/env python3
"""Create explicitly synthetic metadata for optional local interaction checks."""
import datetime
import json
import pathlib
import sqlite3
import sys

root = pathlib.Path(sys.argv[1]).resolve()
if root.exists():
    raise SystemExit("Fixture destination must not exist; existing data is never overwritten.")
(root / "codex" / "sessions").mkdir(parents=True)
(root / "botmux").mkdir()
connection = sqlite3.connect(root / "codex" / "state_5.sqlite")
connection.execute("CREATE TABLE threads (id TEXT, title TEXT, cwd TEXT, source TEXT, rollout_path TEXT)")
now = datetime.datetime.now(datetime.timezone.utc)
for i, title in enumerate(("[测试] 换台原生菜单栏", "[测试] 收藏持久化检查", "[测试] Web 详情入口")):
    session_id = f"00000000-0000-4000-8000-00000000000{i}"
    rollout = root / "codex" / "sessions" / f"fixture-{i}.jsonl"
    date = (now - datetime.timedelta(minutes=i + 1)).isoformat().replace("+00:00", "Z")
    rollout.write_text(json.dumps({"timestamp": date, "type": "response_item", "payload": {
        "type": "message", "role": "assistant", "phase": "final_answer"
    }}) + "\n")
    connection.execute("INSERT INTO threads VALUES (?,?,?,?,?)", (session_id, title, "/fixture/huantai", "cli", str(rollout)))
connection.commit()
connection.close()
print("Created synthetic UI fixture; launch only with HUANTAI_TEST_MODE=1.")
