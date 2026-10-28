# CareGenie

A learning project for the Databricks Certified Context Engineer Associate exam. CareGenie finds diabetic patients who are
overdue for an HbA1c test and answers care-coordinator questions with an agent built from governed data, AI Search and tools.

> **All patient data is synthetic** (Synthea). **The care guidelines are fictional.** Nothing here is medical advice.

## What is in the workspace

Everything lives in Unity Catalog under `caregenie.caregenie`.

| Layer | What | Where |
| --- | --- | --- |
| Raw files | 16 Synthea CSVs in a Volume | `/Volumes/caregenie/caregenie/raw/synthea/` |
| Bronze | Raw Delta tables, unshifted | `notebooks/01_bronze.sql` |
| Silver | Typed, deduped, every date shifted +2,374 days so the newest record is 2026-10-28 | `notebooks/02_silver.sql` |
| Gold | `gold_patient_panel`, `gold_hba1c_gap`, `gold_guidelines`, `gold_encounter_chunks` (+ `_v2` with embeddings) | `notebooks/03_gold.sql`, `03b_gold_embeddings.sql` |
| AI Search | `guidelines_index` (managed embeddings), `encounter_chunks_v2_index` (self-managed embeddings) | endpoint `caregenie-search` |
| Tools | UC functions `overdue_hba1c_patients`, `patient_summary`; procedure `queue_outreach` | `notebooks/04_uc_tools.sql` |
| Agent | LangGraph agent on Agent Bricks / AgentKit, hosted on Databricks Apps | `caregenie-agent/` |

`PLAN.md` has the phase-by-phase build log, findings and open items. Verification queries are in `sql/`.

## Prerequisites

- Databricks CLI v1.22.1+ and Python 3.11+. `sh scripts/setup.sh` installs the CLI and `databricks-agentbricks` into `.venv`.
- `DATABRICKS_HOST` and `DATABRICKS_TOKEN` in the environment. Never put the token in a file or in chat.
- A personal access token with these scopes (this is what the project needed): `files`, `model-serving`,
  `databricks-connect`, `apps`, `scim`, plus the SQL, Unity Catalog and vector-search defaults.
- A serverless SQL warehouse. The scripts default to `acbfda553f05a6ec`; override with `DATABRICKS_WAREHOUSE_ID`.
- Default Storage workspaces cannot create catalogs through the API; `CREATE CATALOG caregenie` through a SQL warehouse works.

## Rebuild the data pipeline

```bash
sh scripts/setup.sh
```

```bash
databricks fs cp -r <unzipped synthea csv folder> dbfs:/Volumes/caregenie/caregenie/raw/synthea --overwrite
```

```bash
for f in notebooks/01_bronze.sql notebooks/02_silver.sql notebooks/03_gold.sql notebooks/03b_gold_embeddings.sql notebooks/04_uc_tools.sql; do python3 scripts/run_sql_file.py $f || break; done
```

```bash
python3 scripts/run_sql_file.py sql/verify_silver_shift.sql
python3 scripts/run_sql_file.py sql/verify_care_gaps.sql
```

The notebooks are idempotent (`CREATE OR REPLACE`, `IF NOT EXISTS`) and can be imported into a workspace as SQL notebooks.
Expected checks: newest silver observation is 2026-10-28, HbA1c gap mismatches are 0, and the care-gap recompute matches gold.

## AI Search

The Standard endpoint `caregenie-search` **bills about $0.28/hour while it exists**, even when idle. Create it only while working,
and delete it when done. Query helpers and experiments:

```bash
python3 scripts/ai_search.py query guidelines "how often should HbA1c be checked"
python3 scripts/ai_search.py experiment-triggered
python3 scripts/ai_search.py experiment-chunk-size
```

## Run the agent locally

```bash
cd caregenie-agent
agentbricks dev
```

Open http://localhost:8000. Local runs use in-memory sessions and have long-term memory off. See `caregenie-agent/README.md`
for the invocation API and `caregenie-agent/AGENTKIT_CONTRACT.md` for the integration contract.

```bash
cd caregenie-agent && uv run pytest
```

## Deploy the agent (Databricks Apps)

Prerequisites: the data pipeline, UC functions and both AI Search indexes above must already exist, and the token needs the
`apps` scope.

1. Deploy from the project directory. A first deploy takes a few minutes (starting app compute).

   ```bash
   cd caregenie-agent
   agentbricks deploy --no-wait
   ```

   ```bash
   agentbricks deployments wait agent-bricks-caregenie
   ```

   The deploy also creates the memory store, session store and tracing experiment declared in `agent.toml`. Run the wait command
   again if it exits with "still deploying".

2. Get the app's service principal. The app runs as this identity, not as you.

   ```bash
   databricks apps get agent-bricks-caregenie -o json
   ```

   Use `service_principal_client_id` as `<SP>` below.

3. Grant it what the tools need (run each statement on the warehouse, for example with `sh scripts/sql.sh "<statement>"`):

   ```sql
   GRANT USE CATALOG ON CATALOG caregenie TO `<SP>`;
   GRANT USE SCHEMA ON SCHEMA caregenie.caregenie TO `<SP>`;
   GRANT EXECUTE ON FUNCTION caregenie.caregenie.overdue_hba1c_patients TO `<SP>`;
   GRANT EXECUTE ON FUNCTION caregenie.caregenie.patient_summary TO `<SP>`;
   GRANT EXECUTE ON PROCEDURE caregenie.caregenie.queue_outreach TO `<SP>`;
   GRANT SELECT ON TABLE caregenie.caregenie.gold_hba1c_gap TO `<SP>`;
   GRANT SELECT ON TABLE caregenie.caregenie.gold_patient_panel TO `<SP>`;
   GRANT SELECT, MODIFY ON TABLE caregenie.caregenie.outreach_queue TO `<SP>`;
   GRANT SELECT ON TABLE caregenie.caregenie.guidelines_index TO `<SP>`;
   GRANT SELECT ON TABLE caregenie.caregenie.encounter_chunks_v2_index TO `<SP>`;
   ```

   Then allow it to use the SQL warehouse. This is an additive update; do not use `set-permissions`, which replaces the whole list.

   ```bash
   databricks warehouses update-permissions <warehouse-id> --json '{"access_control_list":[{"service_principal_name":"<SP>","permission_level":"CAN_USE"}]}'
   ```

4. Open the app URL (`url` in the `apps get` output) in a browser and sign in. Try the sample questions on the start screen.

5. Redeploy after a code change: commit, then run `agentbricks deploy --no-wait` and the wait command again. Grants persist.

### Debugging a deployed agent

- The app's logs and API need an OAuth login, so a personal access token is refused ("OAuth Token not supported for current auth type pat").
  Log in once with `databricks auth login --host <workspace url>`, then:

  ```bash
  databricks apps logs agent-bricks-caregenie --tail-lines 120
  ```

- Tools are constructed when the first question arrives. A failure there fails every question, and the traceback names the tool module.
- Pass the app's own client (`databricks_agentkit.workspace_client()`) to any tool that talks to Databricks. The AI Search client does
  not read the Apps OAuth environment by itself.

### Costs and cleanup

Running billed resources: the AI Search endpoint, the Databricks App, and the Lakebase project `caregenie-memory` (no longer used by the
agent). Remove them when finished. Deleting is permanent, so confirm each one first.

```bash
agentbricks deployments delete agent-bricks-caregenie
```

```bash
databricks vector-search-endpoints delete-endpoint caregenie-search
```

## Findings worth remembering

- Prediabetes is not diabetes: the cohort uses SNOMED 44054006 only. At a 12-month threshold nobody is overdue; use a smaller `months`.
- A `CONTINUOUS` AI Search index is not supported in this workspace; `TRIGGERED` shows new rows about 2 minutes after a sync.
- Managed-embedding sync was about 100 rows/minute here. Precomputing embeddings with `ai_query` and indexing them as
  self-managed embeddings loaded 28,782 chunks in about 3 minutes. Such an index cannot embed query text; the caller must.
- UC SQL functions are read-only, so the one write action is a stored procedure.
- Managed MCP servers are not enabled in this workspace, so UC functions are tools through `UCFunctionToolkit` (needs the
  `databricks-connect` token scope).
