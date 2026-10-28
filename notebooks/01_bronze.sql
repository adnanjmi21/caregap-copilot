-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 01 Bronze: raw Synthea CSVs -> Delta
-- MAGIC All data is synthetic (Synthea). Bronze is raw and unshifted.
-- MAGIC
-- MAGIC `read_files` reads files from a Unity Catalog Volume path and infers types (including timestamps).
-- MAGIC Batch `CREATE OR REPLACE TABLE ... AS SELECT` makes each run idempotent (full reload of the same files).
-- MAGIC For incremental ingestion you would use a `STREAMING TABLE` (Auto Loader under the hood) in a Spark
-- MAGIC Declarative Pipeline; batch is used here because the source is a fixed sample.
-- MAGIC `CLUSTER BY` = liquid clustering (replaces partitioning and ZORDER).

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.bronze_patients CLUSTER BY (Id) AS
SELECT *, current_timestamp() AS _ingested_at, _metadata.file_path AS _source_file
FROM read_files('/Volumes/caregenie/caregenie/raw/synthea/patients.csv', format => 'csv', header => true);

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.bronze_organizations CLUSTER BY (Id) AS
SELECT *, current_timestamp() AS _ingested_at, _metadata.file_path AS _source_file
FROM read_files('/Volumes/caregenie/caregenie/raw/synthea/organizations.csv', format => 'csv', header => true);

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.bronze_conditions CLUSTER BY (PATIENT, CODE) AS
SELECT *, current_timestamp() AS _ingested_at, _metadata.file_path AS _source_file
FROM read_files('/Volumes/caregenie/caregenie/raw/synthea/conditions.csv', format => 'csv', header => true);

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.bronze_medications CLUSTER BY (PATIENT) AS
SELECT *, current_timestamp() AS _ingested_at, _metadata.file_path AS _source_file
FROM read_files('/Volumes/caregenie/caregenie/raw/synthea/medications.csv', format => 'csv', header => true);

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.bronze_observations CLUSTER BY (PATIENT, CODE) AS
SELECT *, current_timestamp() AS _ingested_at, _metadata.file_path AS _source_file
FROM read_files('/Volumes/caregenie/caregenie/raw/synthea/observations.csv', format => 'csv', header => true);

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.bronze_encounters CLUSTER BY (PATIENT) AS
SELECT *, current_timestamp() AS _ingested_at, _metadata.file_path AS _source_file
FROM read_files('/Volumes/caregenie/caregenie/raw/synthea/encounters.csv', format => 'csv', header => true);

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.bronze_procedures CLUSTER BY (PATIENT) AS
SELECT *, current_timestamp() AS _ingested_at, _metadata.file_path AS _source_file
FROM read_files('/Volumes/caregenie/caregenie/raw/synthea/procedures.csv', format => 'csv', header => true);

-- COMMAND ----------

SELECT 'patients' t, count(*) n FROM caregenie.caregenie.bronze_patients
UNION ALL SELECT 'organizations', count(*) FROM caregenie.caregenie.bronze_organizations
UNION ALL SELECT 'conditions', count(*) FROM caregenie.caregenie.bronze_conditions
UNION ALL SELECT 'medications', count(*) FROM caregenie.caregenie.bronze_medications
UNION ALL SELECT 'observations', count(*) FROM caregenie.caregenie.bronze_observations
UNION ALL SELECT 'encounters', count(*) FROM caregenie.caregenie.bronze_encounters
UNION ALL SELECT 'procedures', count(*) FROM caregenie.caregenie.bronze_procedures;
