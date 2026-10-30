# CareGenie: guidance for Claude

Learning project for the Databricks Certified Context Engineer Associate exam. Read `README.md` for the layout and `PLAN.md` for the
build log and open items. The owner is an experienced data engineer new to Databricks: explain Databricks-specific behaviour, skip
generic data-engineering explanations.

## Hard rules

- All patients are synthetic (Synthea). Guidelines are **fictional**; label them so and never present medical advice.
- Never commit CSVs, tokens, `.env`, or local state (`mlflow.db`, `.venv/`, `.agentbricks/`). The workspace uses `DATABRICKS_HOST` and
  `DATABRICKS_TOKEN` from the environment; never ask for the token in chat or write it to a file.
- Ask before anything destructive or billed: `DROP`, `DELETE`, `TRUNCATE`, deleting indexes, endpoints, apps, Lakebase projects,
  or creating new paid resources. A deploy needs an explicit yes. Do not open a PR unless asked.
- Reads and test runs that insert synthetic rows are fine, but say when you wrote data (for example into `outreach_queue`).

## Databricks conventions

- Unity Catalog three-part names (`caregenie.caregenie.<table>`), serverless compute, Delta only, liquid clustering (`CLUSTER BY`),
  idempotent notebooks (`CREATE OR REPLACE`, `IF NOT EXISTS`). `DESCRIBE` a table before assuming its schema.
- Silver shifts every date by a fixed 2,374 days (constant in `silver_date_shift`, never computed from `current_date()`), so gold
  can use `current_date()`. Bronze stays raw. Silver column comments say "synthetic dates, shifted +2374 days".
- Diabetic cohort = SNOMED `44054006` only; Prediabetes (`15777000`) is excluded. HbA1c = LOINC `4548-4`.
- Write table and column `COMMENT`s for an LLM reader. PII columns are tagged `pii=true`; gold tables are tagged `certified=true`.

## How to work here

- Run SQL with `sh scripts/sql.sh "<stmt>"` or `python3 scripts/run_sql_file.py <file>.sql`. Notebooks are SQL notebook source and also run through that script
  (a `CREATE PROCEDURE` must end with a line that is exactly `END;`).
- Agent project is `caregenie-agent/` (see its `AGENTS.md` and `AGENTKIT_CONTRACT.md`). Tools live in `agent/tools/`, one module per
  concern. Run `agentbricks dev` to try it and `uv run pytest` from that folder to test.
- After changing the agent, redeploy with `agentbricks deploy --no-wait` then `agentbricks deployments wait agent-bricks-caregenie`.
- Stopping the local dev server: use `pkill -x databricks`. Never `pkill -f` or `pgrep -f` with a pattern that appears in your own command line, it kills the shell.

- The `databricks` Claude Code plugin is enabled project-wide in `.claude/settings.json` (installed with `databricks aitools install --agents claude-code --scope project`). Its skills load in a new session; use them for Databricks CLI, Apps, Lakebase, Model Serving and jobs questions before guessing.

## Known constraints (do not rediscover)

- Catalogs cannot be created through the API (Default Storage); use `CREATE CATALOG` via a warehouse.
- Docs sites (docs.databricks.com) are not reachable from the cloud sandbox. The Postgres port (Lakebase) is not reachable either.
- Databricks Apps logs and the app API need OAuth; a personal access token is refused. Ask the user to run `databricks apps logs` after
  `databricks auth login`.
- `CONTINUOUS` AI Search indexes and managed MCP servers are not enabled in this workspace.
- Self-managed-embedding indexes cannot embed query text. The managed-embedding sync is slow (about 100 rows/min), so precompute with `ai_query`.
- SQL UDFs are read-only; writes go through a stored procedure (`CALL`). `UCFunctionToolkit` needs the `databricks-connect` token scope.
- Tools that talk to Databricks from the deployed app must be given the app's own client (`databricks_agentkit.workspace_client()`).
- Token scope changes can take a minute or two to apply; retry before assuming they failed.

## Cost reminders

The AI Search endpoint `caregenie-search` bills about $0.28/hour while it exists, and the Databricks App and Lakebase project `caregenie-memory`
also run. Mention open billed resources at the end of a work session and offer to clean up (with confirmation).
