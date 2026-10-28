# CareGenie: Build Plan

Learning project for the Databricks Certified Context Engineer Associate exam (Nov 1, 2026).
All data is synthetic (Synthea). Guidelines are **fictional**. No real medical advice.

Everything lives in one dedicated schema: `caregenie.caregenie` (new catalog `caregenie`, schema `caregenie`).

## Phase 0: Setup (in progress)
- [x] Databricks CLI v1.22.1 installed
- [x] Workspace host + auth (PAT via `DATABRICKS_HOST` / `DATABRICKS_TOKEN` env vars; SQL via `scripts/sql.sh`, `scripts/run_sql_file.py`)
- [x] Confirm catalog, SQL warehouse, and Lakebase/AI Search availability in the workspace
- [x] Create catalog `caregenie`, schema `caregenie` with a Volume `raw` (for the Synthea CSVs)
- [x] Upload Synthea CSVs to the volume (`databricks fs cp`) -> `/Volumes/caregenie/caregenie/raw/synthea/`

## Phase 1: Medallion + governance (success criterion 1) - DONE
Implemented in `notebooks/01_bronze.sql`, `02_silver.sql`, `03_gold.sql` (Databricks SQL notebook source), checks in `sql/`.
Finding: all 57 living diabetics (76 total, 19 deceased) have an HbA1c within the last 11 months, so 0 are overdue at the
12-month threshold (16 are > 6 months, 8 are >= 9 months). The tools take a `months` parameter so Phase 3/5 demos use a lower threshold.
- `01_bronze`: Auto Loader (`read_files` / `cloudFiles`) from the volume into bronze Delta tables, one per CSV
  (patients, conditions, medications, observations, encounters, procedures).
- `02_silver`: typed, deduped, joined on patient/encounter; HbA1c = LOINC 4548-4 from observations.
  - **Date shift (so the data looks current):** the Synthea data ends 2020-04-28. Silver shifts every date and
    timestamp forward by a fixed **2,374 days**, so the newest record lands on 2026-10-28. Whole-interval
    arithmetic is preserved (12-month gaps, ages, medication durations), and `current_date()` logic then works.
  - Applied to: `BIRTHDATE`, `DEATHDATE`, `START`, `STOP`, `DATE` in every silver table, using one shared
    constant from a one-row table `silver_date_shift(shift_days, anchor_date)`, never computed from
    `current_date()` at run time, so re-runs are idempotent and the data does not drift daily.
  - Bronze stays raw and unshifted. Silver column comments state "synthetic dates, shifted +2374 days".
  - Verification: `MAX(observation date)` in silver = 2026-10-28, and per-patient HbA1c gaps in days equal
    bronze gaps exactly.
- `03_gold`:
  - `gold_patient_panel`: one row per patient, with diabetes and hypertension flags.
  - `gold_hba1c_gap`: last HbA1c date and months since, with an `is_overdue` flag (threshold > 12 months).
  - `gold_guidelines`: fictional guideline snippets, labeled as such.
  - `gold_encounter_chunks`: chunked encounter narratives.
- Governance: LLM-oriented table and column `COMMENT`s, PII tags (`pii=true` on SSN, passport, address, phone, name),
  and a `certified=true` tag on gold tables only.
- `sql/verify_care_gaps.sql`: a reproducible spot check against the raw tables.

## Phase 2: AI Search (success criterion 2) - in progress
Endpoint `caregenie-search` (STANDARD, bills ~$0.28/hr while it exists; delete when idle). Indexes `guidelines_index` and
`encounter_chunks_index` (TRIGGERED, `databricks-gte-large-en`). TRIGGERED result: a new guideline was invisible to queries
right after the insert, and appeared about 2 minutes after `sync` was called (`scripts/ai_search.py experiment-triggered`).
Managed-embedding sync of the chunks ran at ~100 rows/min (hours). Fix: precompute embeddings in bulk with `ai_query`
(`notebooks/03b_gold_embeddings.sql`, 25 s for 28,782 chunks) and index them as self-managed embeddings
(`encounter_chunks_v2_index`, loaded in ~3 min). Trade-off: text queries are not accepted, the caller embeds the query.
The slow `encounter_chunks_index` was deleted (user-approved).
Findings:
- CONTINUOUS pipeline type is **not supported in this workspace** (`Pipeline type CONTINUOUS is not supported`), so the
  TRIGGERED-vs-CONTINUOUS comparison is documented from the TRIGGERED result only (stale until `sync`, ~2 min).
- Chunk size (`notebooks/05_chunk_size_experiment.sql`, `scripts/ai_search.py experiment-chunk-size`): small = 28,782
  encounter chunks (152 chars avg), large = 10,962 patient-year chunks (306 chars avg). Mean P@5 = 0.84 small vs 0.80
  large over 5 queries: no meaningful difference because encounter narratives are already short. Large chunks cost
  fewer vectors (62% fewer) but each returned hit carries more unrelated encounters.
- Vocabulary gap: "heart attack" scored P@5 0.20 (small) / 0.00 (large) while "myocardial infarction" finds the
  matching chunks. Lay terms miss SNOMED wording; fixes are query rewriting by the agent or hybrid search.
- Delta Sync indexes on `gold_guidelines` and `gold_encounter_chunks` (Change Data Feed on).
- Experiment: TRIGGERED index, insert a new guideline, query (stale), sync, query (fresh). Compare with CONTINUOUS.
- Chunk-size comparison for encounter narratives.

## Phase 3: UC function tools (success criteria 3 and 4) - tools built and tested (`notebooks/04_uc_tools.sql`)
Note: SQL UDFs are read-only, so the write tool `queue_outreach` is a SQL stored procedure (`CALL`). The tool-confusion demo is still to do.
- Read: `overdue_hba1c_patients(clinic, months)`, `patient_summary(patient_id)`.
- Write: `queue_outreach(patient_id, channel, reason)` inserts into `outreach_queue` with an audit trail
  (user, timestamp, reason).
- Tool-confusion demo: two overlapping tool descriptions give a wrong pick in the trace. Rewrite the descriptions
  and show the fix.

## Phase 4: Agent + memory - agent core and short-term memory built (`agent/caregenie_agent.py`, `scripts/try_agent.py`); Lakebase long-term memory built
- Agent notebook with tools = UC functions + the two AI Search indexes (as retriever tools).
- Short-term memory: thread checkpointing, so follow-up questions resolve against earlier answers (Q6).
- Long-term memory: Lakebase table of per-user preferences (channel, clinic), read by structured query (Q7).
- Routing rule in the system prompt: exact or aggregate means UC function, guideline or similar cases means
  AI Search, user preferences means Lakebase.

Lakebase (Autoscaling project `caregenie-memory`, 0.5-1 CU, suspends after 5 min idle; registered in UC as
`caregenie_lakebase`): `user_preferences` table created and seeded by a one-off serverless job
(`agent/lakebase_setup_job.py`) because the Postgres port is not reachable from the dev sandbox. A UC-registered Lakebase
catalog is read-only (DDL refused), so the agent reads preferences with a structured SQL query through the warehouse.

### Agent Bricks / AgentKit version (`caregenie-agent/`, scaffolded with `agentbricks init`)
Replaces the hand-written classes in `agent/` (kept for comparison). `databricks_agentkit` supplies the LangGraph agent, managed Session
Store checkpointing, managed Memory Store tools and human-in-the-loop approval (`REQUIRE_APPROVAL = {"queue_outreach": True}`, verified:
the agent pauses with an `interrupt`, nothing is written). Tools: two `VectorSearchRetrieverTool` declarations (`agent/tools/search.py`,
works for managed and self-managed-embedding indexes) and one `@tool` function for the write procedure. Model: `system.ai.gpt-oss-120b`
(the Claude gateway services are not enabled in this workspace).
Resolved by adding the `databricks-connect` token scope: UC functions are now tools via `UCFunctionToolkit` (`agent/tools/uc_functions.py`).
The old hand-written agent (`agent/`, Lakebase prefs code, serving wrapper, deploy script) was removed. Earlier blocker: `agentbricks tools add uc-function` loads through Databricks managed MCP, which is a Public Preview not enabled here
("Databricks managed MCP servers are not enabled"), so the agent fails to start with those bindings. Options: enable the preview in
workspace settings, give the token the `databricks-connect` scope (then `UCFunctionToolkit`), or add two small `@tool` wrappers.
Not deployed yet (Databricks Apps); needs approval.

## Phase 5: MLflow 3 tracing and evaluation (success criterion 5)
- Autologging on, and one trace per example question (Q1 to Q7), checking the tool family used.
- Evaluation dataset with the 7 questions plus expected tool family.
- Scorers: built-in (`Safety` or `RelevanceToQuery`) and custom (`used_correct_tool_family`).
- Compare configs A vs B: 3 vs 10 retrieved chunks, and scoped vs raw tool output.
  Run each 3 or more times to see run-to-run variance.

## Repo layout
```
notebooks/  00_setup … 08_eval
sql/        verify_care_gaps.sql
tests/      test_care_gap_logic.py
PLAN.md
```

## Exam-topic study notes
Each notebook ends with a "What this taught" cell mapping to the exam domain.

## Date handling
Care-gap logic uses `current_date()` on shifted silver data. Tools still accept an optional `as_of_date`
so tests and the spot check are reproducible.

## Open questions
1. ~~Catalog name~~ Decided: create new catalog `caregenie`.
2. Are the Synthea CSVs in this session's folder? None were found, so they need to be uploaded.
3. Does the workspace have AI Search (Vector Search) and Lakebase enabled?
