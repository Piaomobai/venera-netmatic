"""End-to-end probe for the "run when the app starts" option.

Sets the task's next_run_at into the FUTURE (so nothing is overdue) and toggles
run_on_start, then reports whether the app ran it shortly after starting. This is
the decisive check: a future slot must only fire on start because of the flag.

Usage:
    python probe_run_on_start.py <db> --arm [--future-minutes N]
    python probe_run_on_start.py <db> --report
    python probe_run_on_start.py <db> --disarm
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


def rel(ms, now_ms):
    if ms is None:
        return "null"
    return f"{ms} ({(ms - now_ms) / 60000.0:+.1f} min)"


def report(con, label):
    row = con.execute(
        "SELECT last_state, last_run_at, next_run_at, run_on_start,"
        " consecutive_failures FROM scheduled_tasks WHERE id = ?",
        (TASK_ID,),
    ).fetchone()
    now_ms = int(time.time() * 1000)
    print(f"=== {label} ===")
    if row is None:
        print("  task not found")
        return
    print(f"  run_on_start         = {row['run_on_start']}")
    print(f"  last_state           = {row['last_state']}")
    print(f"  last_run_at          = {rel(row['last_run_at'], now_ms)}")
    print(f"  next_run_at          = {rel(row['next_run_at'], now_ms)}")
    runs = list(
        con.execute(
            "SELECT id, state, message FROM task_runs WHERE task_id = ?"
            " ORDER BY started_at",
            (TASK_ID,),
        )
    )
    print(f"  run history rows     = {len(runs)}")
    for r in runs:
        print(f"    #{r['id']} {r['state']}: {r['message']}")


def arm(con, future_minutes):
    now_ms = int(time.time() * 1000)
    future = now_ms + future_minutes * 60 * 1000
    con.execute(
        "UPDATE scheduled_tasks SET next_run_at = ?, run_on_start = 1,"
        " last_state = 'never', last_run_at = NULL, last_error = NULL,"
        " consecutive_failures = 0 WHERE id = ?",
        (future, TASK_ID),
    )
    con.execute("DELETE FROM task_runs WHERE task_id = ?", (TASK_ID,))
    con.commit()
    print(f"armed: next run {future_minutes} min in the FUTURE, run_on_start=1")
    report(con, "state after arming")


def disarm(con):
    """Undo `arm()` so an end-to-end probe leaves no trace in a real library."""
    con.execute(
        "UPDATE scheduled_tasks SET run_on_start = 0 WHERE id = ?", (TASK_ID,)
    )
    con.commit()
    print("disarmed: run_on_start=0")
    report(con, "state after disarming")


def main():
    con = connect()
    if "--report" in sys.argv:
        report(con, "state now")
    elif "--disarm" in sys.argv:
        disarm(con)
    else:
        idx = sys.argv.index("--future-minutes") if "--future-minutes" in sys.argv else -1
        minutes = int(sys.argv[idx + 1]) if idx != -1 else 240
        arm(con, minutes)
    con.close()


main()
