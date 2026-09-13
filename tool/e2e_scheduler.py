"""End-to-end probe for the built venera scheduler.

Inserts one due task into the database the real app created, so that the built
executable can be asked to list it and run it. This exercises the store schema,
the engine's due-task dispatch, the runner, and run-history persistence through
the actual Windows binary -- not through a test harness.

Usage:
    python e2e_scheduler.py <path-to-scheduler.db> [--report]
"""

import json
import sqlite3
import sys
import time

DB = sys.argv[1]
REPORT_ONLY = "--report" in sys.argv


def connect():
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    return con


def show_schema(con):
    print("=== schema ===")
    for row in con.execute(
        "SELECT type, name FROM sqlite_master ORDER BY type, name"
    ):
        print(f"  {row['type']:<6} {row['name']}")


def insert_due_task(con):
    now_ms = int(time.time() * 1000)
    schedule = {"type": "interval", "intervalSeconds": 1800}
    config = {
        "sources": [],
        "options": [],
        "pagesPerOption": 1,
        "maxNewPerRun": 50,
        "throttleMs": 300,
        "autoFavorite": False,
        "favoriteFolder": "",
        "autoDownload": False,
        "forgetAfterDays": 90,
    }
    retry = {
        "maxAttempts": 1,
        "initialDelaySeconds": 60,
        "backoffMultiplier": 2.0,
        "maxDelaySeconds": 3600,
    }
    con.execute("DELETE FROM scheduled_tasks WHERE id = ?", ("e2e-test-task",))
    con.execute("DELETE FROM task_runs WHERE task_id = ?", ("e2e-test-task",))
    con.execute(
        """
        INSERT INTO scheduled_tasks (
          id, type_key, name, enabled, schedule, config, retry, sort_order,
          created_at, last_run_at, next_run_at, last_state, last_error,
          consecutive_failures, last_summary
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            "e2e-test-task",
            "rankingMonitor",
            "E2E ranking scan",
            1,
            json.dumps(schedule),
            json.dumps(config),
            json.dumps(retry),
            0,
            now_ms,
            None,
            now_ms - 60000,  # already due
            "never",
            None,
            0,
            None,
        ),
    )
    con.commit()
    print("inserted 1 due task (next_run_at 60s in the past)")


def report(con):
    print("=== scheduled_tasks ===")
    for row in con.execute(
        "SELECT id, type_key, enabled, last_state, last_error, next_run_at,"
        " consecutive_failures, last_summary FROM scheduled_tasks"
    ):
        print(f"  id={row['id']} type={row['type_key']} enabled={row['enabled']}")
        print(f"    last_state={row['last_state']}")
        print(f"    last_error={row['last_error']}")
        print(f"    consecutive_failures={row['consecutive_failures']}")
        print(f"    last_summary={row['last_summary']}")
        print(f"    next_run_at={row['next_run_at']}")

    print("=== task_runs ===")
    rows = list(
        con.execute(
            "SELECT id, task_id, started_at, finished_at, state, message, error,"
            " summary FROM task_runs ORDER BY started_at"
        )
    )
    if not rows:
        print("  (none)")
    for row in rows:
        duration = (
            (row["finished_at"] - row["started_at"]) / 1000.0
            if row["finished_at"]
            else None
        )
        print(f"  id={row['id']} task={row['task_id']} state={row['state']}")
        print(f"    duration={duration}s")
        print(f"    message={row['message']}")
        print(f"    error={row['error']}")
        print(f"    summary={row['summary']}")


def main():
    con = connect()
    show_schema(con)
    print()
    if REPORT_ONLY:
        report(con)
    else:
        insert_due_task(con)
    con.close()


main()
