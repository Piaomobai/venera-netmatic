"""Dumps one scheduled task in full, decoding its JSON columns.

Usage: python dump_task.py <db> [task_id]
"""

import json
import sqlite3
import sys
import time

DB = sys.argv[1]
TASK_ID = sys.argv[2] if len(sys.argv) > 2 else "e2e-test-task"

con = sqlite3.connect(DB)
con.row_factory = sqlite3.Row

cols = [r["name"] for r in con.execute("PRAGMA table_info(scheduled_tasks);")]
row = con.execute("SELECT * FROM scheduled_tasks WHERE id = ?", (TASK_ID,)).fetchone()

if row is None:
    print(f"task {TASK_ID} not found")
    sys.exit(1)

now_ms = int(time.time() * 1000)
print(f"columns: {', '.join(cols)}")
print()
for key in row.keys():
    value = row[key]
    if key in ("schedule", "config", "retry", "last_summary") and isinstance(value, str):
        print(f"  {key:22} = {json.dumps(json.loads(value), ensure_ascii=False)}")
    elif key.endswith("_at") and isinstance(value, int):
        delta_min = (value - now_ms) / 60000.0
        print(f"  {key:22} = {value}  ({delta_min:+.1f} min from now)")
    else:
        print(f"  {key:22} = {value}")
