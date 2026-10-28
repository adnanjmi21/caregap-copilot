-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 03b Gold: encounter chunks with precomputed embeddings
-- MAGIC A Delta Sync index with *managed* embeddings calls the embedding endpoint in small throttled batches
-- MAGIC (about 100 rows/min here). Computing embeddings in bulk with `ai_query` on the warehouse is parallel
-- MAGIC (about 200 rows/s here), and the index then loads ready-made vectors ("self-managed embeddings").
-- MAGIC The index keeps `embedding_model_endpoint_name` so text queries are still embedded at query time.
-- MAGIC `databricks-gte-large-en` returns 1024-dimension vectors.

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.gold_encounter_chunks_v2
TBLPROPERTIES (delta.enableChangeDataFeed = true) AS
SELECT chunk_id, patient_id, clinic, encounter_date, chunk_text,
       ai_query('databricks-gte-large-en', chunk_text) AS embedding
FROM caregenie.caregenie.gold_encounter_chunks;

-- COMMAND ----------

COMMENT ON TABLE caregenie.caregenie.gold_encounter_chunks_v2 IS 'One short text narrative per encounter for diabetic or hypertensive synthetic patients, with a precomputed 1024-dim embedding (databricks-gte-large-en) of chunk_text. Built for semantic search over visit history. Contains no names or direct PII.';
ALTER TABLE caregenie.caregenie.gold_encounter_chunks_v2 ALTER COLUMN chunk_text COMMENT 'Natural-language summary of one synthetic encounter; this is the text that was embedded';
ALTER TABLE caregenie.caregenie.gold_encounter_chunks_v2 ALTER COLUMN embedding COMMENT 'Embedding of chunk_text from databricks-gte-large-en (1024 dimensions)';
ALTER TABLE caregenie.caregenie.gold_encounter_chunks_v2 SET TAGS ('certified' = 'true');

-- COMMAND ----------

SELECT count(*) AS chunks, min(size(embedding)) AS min_dim, max(size(embedding)) AS max_dim, count_if(embedding IS NULL) AS null_embeddings
FROM caregenie.caregenie.gold_encounter_chunks_v2;
