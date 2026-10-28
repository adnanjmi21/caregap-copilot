#!/usr/bin/env python3
"""Small helpers for the AI Search (Vector Search) experiments. Uses the Databricks CLI for auth.

  python3 scripts/ai_search.py query guidelines "how often should HbA1c be checked" [num_results]
  python3 scripts/ai_search.py sync guidelines
  python3 scripts/ai_search.py experiment-triggered
"""
import json, subprocess, sys, time

IDX = {"guidelines": "caregenie.caregenie.guidelines_index",
       "chunks": "caregenie.caregenie.encounter_chunks_v2_index",
       "chunks_large": "caregenie.caregenie.encounter_chunks_large_index"}
COLS = {"guidelines": ["guideline_id", "title", "content"],
        "chunks": ["chunk_id", "clinic", "encounter_date", "chunk_text"],
        "chunks_large": ["chunk_id", "clinic", "encounter_date", "chunk_text"]}


def api(method, path, body=None):
    cmd = ["databricks", "api", method, path] + (["--json", json.dumps(body)] if body is not None else [])
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stderr or r.stdout)
    return json.loads(r.stdout) if r.stdout.strip() else {}


def embed(text):
    """Self-managed-embedding indexes cannot embed query text, so embed it with the same model used for the data."""
    r = api("post", "/serving-endpoints/databricks-gte-large-en/invocations", {"input": [text]})
    return r["data"][0]["embedding"]


def query(which, text, n=3):
    body = {"columns": COLS[which], "num_results": n}
    self_managed = which.startswith("chunks")
    body["query_vector" if self_managed else "query_text"] = embed(text) if self_managed else text
    r = api("post", f"/api/2.0/vector-search/indexes/{IDX[which]}/query", body)
    return r.get("result", {}).get("data_array", [])


def sync(which):
    api("post", f"/api/2.0/vector-search/indexes/{IDX[which]}/sync")


def row_count(which):
    return api("get", f"/api/2.0/vector-search/indexes/{IDX[which]}")["status"].get("indexed_row_count")


def wait_synced(which, before, timeout=900):
    """A sync is asynchronous: `ready` stays True while it runs, so wait for the row count to change."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        if row_count(which) != before:
            return row_count(which)
        time.sleep(15)
    raise TimeoutError(which)


def sql(stmt):
    r = api("post", "/api/2.0/sql/statements", {"warehouse_id": "acbfda553f05a6ec", "statement": stmt, "wait_timeout": "50s"})
    assert r["status"]["state"] == "SUCCEEDED", r["status"]
    return r


def experiment_triggered():
    q = "when should a patient be referred for eye screening"
    sql("""MERGE INTO caregenie.caregenie.gold_guidelines t USING (SELECT 'G009' guideline_id,
      'Eye screening for diabetes' title, 'diabetes' topic,
      'FICTIONAL GUIDELINE: Adults with diabetes should be referred for a dilated eye screening exam every 12 months.' content) s
      ON t.guideline_id = s.guideline_id WHEN NOT MATCHED THEN INSERT *""")
    print("Inserted G009 into the Delta source table (Change Data Feed captures it).")
    print("Query BEFORE sync (TRIGGERED index is stale):")
    for r in query("guidelines", q, 2): print("  ", r[0], r[1])
    before = row_count("guidelines")
    sync("guidelines")
    t0 = time.time()
    if before is not None and wait_synced("guidelines", before):
        print(f"Sync finished in {time.time() - t0:.0f}s")
    print("Query AFTER sync:")
    for r in query("guidelines", q, 2): print("  ", r[0], r[1])


def experiment_chunk_size(k=5):
    """Precision@k: share of the top-k chunks whose text mentions the target condition, small vs large chunks."""
    cases = [("retinopathy eye damage from diabetes", ["retinopathy"]),
             ("kidney complication of diabetes", ["renal", "albuminuria", "nephro"]),
             ("nerve damage in the feet", ["neuropathy"]),
             ("patient with high blood pressure", ["hypertension"]),
             ("heart attack history", ["myocardial"])]
    print(f"{'query':45} {'P@%d small' % k:>11} {'P@%d large' % k:>11} {'avg chars small':>16} {'avg chars large':>16}")
    tot = {"chunks": 0, "chunks_large": 0}
    for q, kws in cases:
        row = {}
        for which in ("chunks", "chunks_large"):
            res = query(which, q, k)
            hits = sum(any(w in r[3].lower() for w in kws) for r in res)
            row[which] = (hits / k, sum(len(r[3]) for r in res) / max(len(res), 1))
            tot[which] += hits / k
        print(f"{q:45} {row['chunks'][0]:>11.2f} {row['chunks_large'][0]:>11.2f} {row['chunks'][1]:>16.0f} {row['chunks_large'][1]:>16.0f}")
    n = len(cases)
    print(f"{'MEAN':45} {tot['chunks'] / n:>11.2f} {tot['chunks_large'] / n:>11.2f}")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "query":
        for r in query(sys.argv[2], sys.argv[3], int(sys.argv[4]) if len(sys.argv) > 4 else 3): print(r)
    elif cmd == "sync":
        before = row_count(sys.argv[2]); sync(sys.argv[2]); print(wait_synced(sys.argv[2], before))
    elif cmd == "experiment-chunk-size":
        experiment_chunk_size()
    elif cmd == "experiment-triggered":
        experiment_triggered()
