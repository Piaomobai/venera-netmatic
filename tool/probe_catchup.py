"""Probe what the scheduler does with a task whose run was missed while the app
was closed.

Backdates a task's next_run_at into the past (simulating "the app was shut down
when this should have fired"), then reports what the app did after it started.

Usage:
    python probe_catchup.py <db> --backdate <minutes>
    python probe_catchup.py <db> --report
"""

import sqlite3
import sys
import time

DB = sys.argv[1]
TASK_ID = "e2e-test-task"


def connect():
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    return con


def report(con, label):
    row = con.execute(
        "SELECT last_state, last_run_at, next_run_at, consecutive_failures"
        " FROM scheduled_tasks WHERE id = ?",
        (TASK_ID,),
    ).fetchone()
    if row is None:
        print(f"{label}: task not found")
        return
    now_ms = int(time.time() * 1000)

    def rel(ms):
        if ms is None:
            return "null"
        delta_min = (ms - now_ms) / 60000.0
        return f"{ms} ({delta_min:+.1f} min from now)"

    print(f"=== {label} ===")
    print(f"  last_state           = {row['last_state']}")
    print(f"  last_run_at          = {rel(row['last_run_at'])}")
    print(f"  next_run_at          = {rel(row['next_run_at'])}")
    print(f"  consecutive_failures = {row['consecutive_failures']}")
    runs = list(
        con.execute(
            "SELECT id, state, message, started_at FROM task_runs"
            " WHERE task_id = ? ORDER BY started_at",
            (TASK_ID,),
        )
    )
    print(f"  run history rows     = {len(runs)}")
    for r in runs:
        print(f"    #{r['id']} {r['state']}: {r['message']}")


def backdate(con, minutes):
    now_ms = int(time.time() * 1000)
    past = now_ms - minutes * 60 * 1000
    con.execute(
        "UPDATE scheduled_tasks SET next_run_at = ?, last_state = 'never',"
        " last_run_at = NULL, last_error = NULL, consecutive_failures = 0"
        " WHERE id = ?",
        (past, TASK_ID),
    )
    con.execute("DELETE FROM task_runs WHERE task_id = ?", (TASK_ID,))
    con.commit()
    print(f"backdated next_run_at by {minutes} minutes (now overdue)")
    report(con, "state after backdating")


def main():
    con = connect()
    if "--report" in sys.argv:
        report(con, "state now")
    else:
        idx = sys.argv.index("--backdate")
        backdate(con, int(sys.argv[idx + 1]))
    con.close()


main()
