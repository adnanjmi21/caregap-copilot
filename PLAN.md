# CareGenie: Build Plan

Learning project for the Databricks Certified Context Engineer Associate exam (Nov 1, 2026).
All data is synthetic (Synthea). Guidelines are **fictional**. No real medical advice.

Everything lives in one dedicated schema: `caregenie.caregenie` (new catalog `caregenie`, schema `caregenie`).

## Phase 0: Setup (in progress)
- [x] Databricks CLI v1.22.1 installed
- [ ] Workspace host + auth (OAuth U2M preferred, PAT as fallback) into a `caregenie` CLI profile
- [x] Confirm catalog, SQL warehouse, and Lakebase/AI Search availability in the workspace
- [x] Create catalog `caregenie`, schema `caregenie` with a Volume `raw` (for the Synthea CSVs)
- [ ] Upload Synthea CSVs to the volume (`databricks fs cp`)

## Phase 1: Medallion + governance (success criterion 1)
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

## Phase 2: AI Search (success criterion 2)
- Delta Sync indexes on `gold_guidelines` and `gold_encounter_chunks` (Change Data Feed on).
- Experiment: TRIGGERED index, insert a new guideline, query (stale), sync, query (fresh). Compare with CONTINUOUS.
- Chunk-size comparison for encounter narratives.

## Phase 3: UC function tools (success criteria 3 and 4)
- Read: `overdue_hba1c_patients(clinic, months)`, `patient_summary(patient_id)`.
- Write: `queue_outreach(patient_id, channel, reason)` inserts into `outreach_queue` with an audit trail
  (user, timestamp, reason).
- Tool-confusion demo: two overlapping tool descriptions give a wrong pick in the trace. Rewrite the descriptions
  and show the fix.

## Phase 4: Agent + memory
- Agent notebook with tools = UC functions + the two AI Search indexes (as retriever tools).
- Short-term memory: thread checkpointing, so follow-up questions resolve against earlier answers (Q6).
- Long-term memory: Lakebase table of per-user preferences (channel, clinic), read by structured query (Q7).
- Routing rule in the system prompt: exact or aggregate means UC function, guideline or similar cases means
  AI Search, user preferences means Lakebase.

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
