#!/usr/bin/env python3
"""Run a .sql notebook file statement by statement on the serverless warehouse.

Usage: python3 scripts/run_sql_file.py notebooks/01_bronze.sql [--show-last]
Statements end with a line-final ';' (a CREATE PROCEDURE ends at a line that is exactly 'END;'). Comment-only chunks are skipped.
"""
import json, os, subprocess, sys, time

WH = os.environ.get("DATABRICKS_WAREHOUSE_ID", "acbfda553f05a6ec")


def api(method, path, body=None):
    cmd = ["databricks", "api", method, path]
    if body is not None:
        cmd += ["--json", json.dumps(body)]
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr or out.stdout)
    return json.loads(out.stdout)


def run(stmt):
    r = api("post", "/api/2.0/sql/statements", {
        "warehouse_id": WH, "statement": stmt, "wait_timeout": "50s",
        "catalog": "caregenie", "schema": "caregenie"})
    while r["status"]["state"] in ("PENDING", "RUNNING"):
        time.sleep(3)
        r = api("get", f"/api/2.0/sql/statements/{r['statement_id']}")
    return r


def split(text):
    stmts, cur = [], []
    for line in text.splitlines():
        if not cur and (not line.strip() or line.strip().startswith("--")):
            continue
        cur.append(line)
        in_proc = "PROCEDURE" in cur[0].upper()  # compound body: only a lone END; closes it
        if (line.strip() == "END;") if in_proc else line.rstrip().endswith(";"):
            stmts.append("\n".join(cur).rstrip().rstrip(";"))
            cur = []
    if cur:
        stmts.append("\n".join(cur))
    return stmts


if __name__ == "__main__":
    path, show = sys.argv[1], "--show-last" in sys.argv
    stmts = split(open(path).read())
    for i, s in enumerate(stmts, 1):
        r = run(s)
        head = " ".join(s.split())[:90]
        if r["status"]["state"] != "SUCCEEDED":
            print(f"[{i}/{len(stmts)}] FAILED: {head}\n  {r['status'].get('error', {}).get('message')}")
            sys.exit(1)
        rows = r.get("result", {}).get("data_array")
        print(f"[{i}/{len(stmts)}] ok: {head}")
        if rows and (show or i == len(stmts)):
            cols = [c["name"] for c in r["manifest"]["schema"]["columns"]]
            print("  ", cols)
            for row in rows[:50]:
                print("  ", row)
