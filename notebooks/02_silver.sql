-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 02 Silver: typed, deduped, date-shifted
-- MAGIC Synthea data ends 2020-04-28. Silver shifts every date/timestamp (BIRTHDATE, DEATHDATE, START, STOP, DATE)
-- MAGIC forward by a fixed **2,374 days** so the newest record lands on **2026-10-28**.
-- MAGIC The constant lives in a one-row table and is never derived from `current_date()`, so re-runs are idempotent.
-- MAGIC
-- MAGIC Unity Catalog note: `COMMENT` and `TAGS` are stored in the metastore and surface in Catalog Explorer;
-- MAGIC LLM-facing tools (Genie, agents) read the comments, so they are written for a model, not just a human.

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.silver_date_shift
COMMENT 'Single-row constant for the silver date shift. Synthea data ends 2020-04-28; adding shift_days lands the newest record on anchor_date. Fixed on purpose, never computed from current_date().'
AS SELECT 2374 AS shift_days, DATE'2026-10-28' AS anchor_date;

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.silver_patients CLUSTER BY (patient_id) AS
SELECT
  Id AS patient_id,
  date_add(BIRTHDATE, s.shift_days) AS birthdate,
  date_add(DEATHDATE, s.shift_days) AS deathdate,
  SSN AS ssn, DRIVERS AS drivers, PASSPORT AS passport,
  PREFIX AS prefix, FIRST AS first_name, LAST AS last_name, SUFFIX AS suffix, MAIDEN AS maiden_name,
  MARITAL AS marital_status, RACE AS race, ETHNICITY AS ethnicity, GENDER AS gender, BIRTHPLACE AS birthplace,
  ADDRESS AS address, CITY AS city, STATE AS state, COUNTY AS county,
  lpad(CAST(ZIP AS STRING), 5, '0') AS zip,
  LAT AS lat, LON AS lon,
  HEALTHCARE_EXPENSES AS healthcare_expenses, HEALTHCARE_COVERAGE AS healthcare_coverage
FROM caregenie.caregenie.bronze_patients
CROSS JOIN caregenie.caregenie.silver_date_shift s
QUALIFY row_number() OVER (PARTITION BY Id ORDER BY _ingested_at) = 1;

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.silver_organizations CLUSTER BY (organization_id) AS
SELECT Id AS organization_id, NAME AS name, ADDRESS AS address, CITY AS city, STATE AS state,
       CAST(ZIP AS STRING) AS zip, PHONE AS phone
FROM caregenie.caregenie.bronze_organizations
QUALIFY row_number() OVER (PARTITION BY Id ORDER BY _ingested_at) = 1;

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.silver_conditions CLUSTER BY (patient_id, code) AS
SELECT DISTINCT
  date_add(START, s.shift_days) AS start_date,
  date_add(STOP, s.shift_days) AS stop_date,
  PATIENT AS patient_id, ENCOUNTER AS encounter_id,
  CAST(CODE AS STRING) AS code, DESCRIPTION AS description
FROM caregenie.caregenie.bronze_conditions
CROSS JOIN caregenie.caregenie.silver_date_shift s;

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.silver_encounters CLUSTER BY (patient_id) AS
SELECT
  Id AS encounter_id,
  timestampadd(DAY, s.shift_days, START) AS start_ts,
  timestampadd(DAY, s.shift_days, STOP) AS stop_ts,
  PATIENT AS patient_id, ORGANIZATION AS organization_id, PROVIDER AS provider_id,
  ENCOUNTERCLASS AS encounter_class, CAST(CODE AS STRING) AS code, DESCRIPTION AS description,
  BASE_ENCOUNTER_COST AS base_encounter_cost, TOTAL_CLAIM_COST AS total_claim_cost,
  CAST(REASONCODE AS STRING) AS reason_code, REASONDESCRIPTION AS reason_description
FROM caregenie.caregenie.bronze_encounters
CROSS JOIN caregenie.caregenie.silver_date_shift s
QUALIFY row_number() OVER (PARTITION BY Id ORDER BY _ingested_at) = 1;

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.silver_medications CLUSTER BY (patient_id) AS
SELECT DISTINCT
  timestampadd(DAY, s.shift_days, START) AS start_ts,
  timestampadd(DAY, s.shift_days, STOP) AS stop_ts,
  PATIENT AS patient_id, ENCOUNTER AS encounter_id, CAST(CODE AS STRING) AS code,
  DESCRIPTION AS description, DISPENSES AS dispenses, TOTALCOST AS total_cost,
  CAST(REASONCODE AS STRING) AS reason_code, REASONDESCRIPTION AS reason_description
FROM caregenie.caregenie.bronze_medications
CROSS JOIN caregenie.caregenie.silver_date_shift s;

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.silver_observations CLUSTER BY (patient_id, code) AS
SELECT DISTINCT
  timestampadd(DAY, s.shift_days, DATE) AS observation_ts,
  PATIENT AS patient_id, ENCOUNTER AS encounter_id, CODE AS code, DESCRIPTION AS description,
  VALUE AS value, UNITS AS units, TYPE AS value_type
FROM caregenie.caregenie.bronze_observations
CROSS JOIN caregenie.caregenie.silver_date_shift s;

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.silver_procedures CLUSTER BY (patient_id) AS
SELECT DISTINCT
  timestampadd(DAY, s.shift_days, DATE) AS procedure_ts,
  PATIENT AS patient_id, ENCOUNTER AS encounter_id, CAST(CODE AS STRING) AS code,
  DESCRIPTION AS description, CAST(REASONCODE AS STRING) AS reason_code, REASONDESCRIPTION AS reason_description
FROM caregenie.caregenie.bronze_procedures
CROSS JOIN caregenie.caregenie.silver_date_shift s;

-- COMMAND ----------

COMMENT ON TABLE caregenie.caregenie.silver_patients IS 'One row per synthetic patient (Synthea, not real people). Cleaned patient demographics; all dates shifted +2374 days. Contains synthetic PII columns tagged pii=true.';
COMMENT ON TABLE caregenie.caregenie.silver_organizations IS 'Synthetic healthcare organizations (clinics and hospitals) referenced by encounters.';
COMMENT ON TABLE caregenie.caregenie.silver_conditions IS 'Synthetic patient diagnoses. code is a SNOMED CT code. Diabetes is 44054006; Prediabetes (15777000) is NOT diabetes. Dates shifted +2374 days.';
COMMENT ON TABLE caregenie.caregenie.silver_encounters IS 'Synthetic patient encounters (visits). organization_id is the clinic. Timestamps shifted +2374 days.';
COMMENT ON TABLE caregenie.caregenie.silver_medications IS 'Synthetic medication orders. Timestamps shifted +2374 days.';
COMMENT ON TABLE caregenie.caregenie.silver_observations IS 'Synthetic observations and lab results. code is a LOINC code; HbA1c is 4548-4 (value in %). Timestamps shifted +2374 days.';
COMMENT ON TABLE caregenie.caregenie.silver_procedures IS 'Synthetic procedures performed. Timestamps shifted +2374 days.';

-- COMMAND ----------

ALTER TABLE caregenie.caregenie.silver_patients ALTER COLUMN birthdate COMMENT 'Date of birth. Synthetic dates, shifted +2374 days';
ALTER TABLE caregenie.caregenie.silver_patients ALTER COLUMN deathdate COMMENT 'Date of death, NULL if alive. Synthetic dates, shifted +2374 days';
ALTER TABLE caregenie.caregenie.silver_conditions ALTER COLUMN start_date COMMENT 'Diagnosis start date. Synthetic dates, shifted +2374 days';
ALTER TABLE caregenie.caregenie.silver_conditions ALTER COLUMN stop_date COMMENT 'Diagnosis end date, NULL if ongoing. Synthetic dates, shifted +2374 days';
ALTER TABLE caregenie.caregenie.silver_conditions ALTER COLUMN code COMMENT 'SNOMED CT condition code';
ALTER TABLE caregenie.caregenie.silver_encounters ALTER COLUMN start_ts COMMENT 'Encounter start. Synthetic dates, shifted +2374 days';
ALTER TABLE caregenie.caregenie.silver_encounters ALTER COLUMN stop_ts COMMENT 'Encounter end. Synthetic dates, shifted +2374 days';
ALTER TABLE caregenie.caregenie.silver_medications ALTER COLUMN start_ts COMMENT 'Medication start. Synthetic dates, shifted +2374 days';
ALTER TABLE caregenie.caregenie.silver_medications ALTER COLUMN stop_ts COMMENT 'Medication end, NULL if ongoing. Synthetic dates, shifted +2374 days';
ALTER TABLE caregenie.caregenie.silver_observations ALTER COLUMN observation_ts COMMENT 'When the observation was recorded. Synthetic dates, shifted +2374 days';
ALTER TABLE caregenie.caregenie.silver_observations ALTER COLUMN code COMMENT 'LOINC code; HbA1c = 4548-4';
ALTER TABLE caregenie.caregenie.silver_observations ALTER COLUMN value COMMENT 'Result as text; numeric when value_type = numeric. HbA1c is a percentage';
ALTER TABLE caregenie.caregenie.silver_procedures ALTER COLUMN procedure_ts COMMENT 'When the procedure was performed. Synthetic dates, shifted +2374 days';

-- COMMAND ----------

ALTER TABLE caregenie.caregenie.silver_patients ALTER COLUMN ssn SET TAGS ('pii' = 'true');
ALTER TABLE caregenie.caregenie.silver_patients ALTER COLUMN drivers SET TAGS ('pii' = 'true');
ALTER TABLE caregenie.caregenie.silver_patients ALTER COLUMN passport SET TAGS ('pii' = 'true');
ALTER TABLE caregenie.caregenie.silver_patients ALTER COLUMN first_name SET TAGS ('pii' = 'true');
ALTER TABLE caregenie.caregenie.silver_patients ALTER COLUMN last_name SET TAGS ('pii' = 'true');
ALTER TABLE caregenie.caregenie.silver_patients ALTER COLUMN maiden_name SET TAGS ('pii' = 'true');
ALTER TABLE caregenie.caregenie.silver_patients ALTER COLUMN address SET TAGS ('pii' = 'true');
ALTER TABLE caregenie.caregenie.silver_patients ALTER COLUMN city SET TAGS ('pii' = 'true');
ALTER TABLE caregenie.caregenie.silver_patients ALTER COLUMN zip SET TAGS ('pii' = 'true');
ALTER TABLE caregenie.caregenie.silver_patients ALTER COLUMN lat SET TAGS ('pii' = 'true');
ALTER TABLE caregenie.caregenie.silver_patients ALTER COLUMN lon SET TAGS ('pii' = 'true');
ALTER TABLE caregenie.caregenie.silver_patients ALTER COLUMN birthdate SET TAGS ('pii' = 'true');

-- COMMAND ----------

-- Verification 1: newest observation lands on the anchor date (expect 2026-10-28 and true)
SELECT max(CAST(o.observation_ts AS DATE)) AS max_silver_obs_date,
       max(CAST(o.observation_ts AS DATE)) = max(d.anchor_date) AS matches_anchor
FROM caregenie.caregenie.silver_observations o CROSS JOIN caregenie.caregenie.silver_date_shift d;
