-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 05 Chunk-size experiment (Phase 2)
-- MAGIC Small chunks = one encounter narrative (gold_encounter_chunks_v2).
-- MAGIC Large chunks = all of one patient's encounter narratives in one calendar year, capped at 1500 characters.
-- MAGIC Same embedding model, same index type. Compare retrieval with `scripts/chunk_experiment.py`.

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.gold_encounter_chunks_large
TBLPROPERTIES (delta.enableChangeDataFeed = true) AS
WITH grouped AS (
  SELECT concat(patient_id, '-', year(encounter_date)) AS chunk_id, patient_id, any_value(clinic) AS clinic,
         min(encounter_date) AS encounter_date,
         substr(array_join(array_sort(collect_list(concat(CAST(encounter_date AS STRING), '|', chunk_text))), ' '), 1, 1500) AS chunk_text
  FROM caregenie.caregenie.gold_encounter_chunks_v2
  GROUP BY patient_id, year(encounter_date)
)
SELECT *, ai_query('databricks-gte-large-en', chunk_text) AS embedding FROM grouped;

-- COMMAND ----------

SELECT count(*) AS large_chunks, round(avg(length(chunk_text))) AS avg_chars,
       (SELECT count(*) FROM caregenie.caregenie.gold_encounter_chunks_v2) AS small_chunks,
       (SELECT round(avg(length(chunk_text))) FROM caregenie.caregenie.gold_encounter_chunks_v2) AS small_avg_chars
FROM caregenie.caregenie.gold_encounter_chunks_large;
