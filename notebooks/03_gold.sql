-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 03 Gold: care-gap tables (certified)
-- MAGIC Silver dates are shifted so the newest record is 2026-10-28, which lets gold use `current_date()`.
-- MAGIC All data is synthetic (Synthea). The guidelines are FICTIONAL and are not medical advice.
-- MAGIC Diabetic cohort = SNOMED 44054006 (Diabetes) only; Prediabetes (15777000) is excluded.
-- MAGIC HbA1c = LOINC 4548-4. Hypertension = SNOMED 59621000.
-- MAGIC Gold tables carry the `certified = true` tag and contain no direct PII columns.

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.gold_patient_panel CLUSTER BY (patient_id) AS
WITH last_enc AS (
  SELECT patient_id, organization_id, CAST(start_ts AS DATE) AS last_encounter_date
  FROM caregenie.caregenie.silver_encounters
  QUALIFY row_number() OVER (PARTITION BY patient_id ORDER BY start_ts DESC) = 1
), flags AS (
  SELECT patient_id,
         max(code = '44054006') AS is_diabetic,
         max(code = '59621000') AS has_hypertension
  FROM caregenie.caregenie.silver_conditions
  GROUP BY patient_id
)
SELECT
  p.patient_id,
  p.gender,
  CAST(floor(months_between(coalesce(p.deathdate, current_date()), p.birthdate) / 12) AS INT) AS age_years,
  p.deathdate IS NOT NULL AS is_deceased,
  o.name AS clinic,
  e.last_encounter_date,
  coalesce(f.is_diabetic, false) AS is_diabetic,
  coalesce(f.has_hypertension, false) AS has_hypertension,
  current_date() AS as_of_date
FROM caregenie.caregenie.silver_patients p
LEFT JOIN last_enc e USING (patient_id)
LEFT JOIN caregenie.caregenie.silver_organizations o ON o.organization_id = e.organization_id
LEFT JOIN flags f USING (patient_id);

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.gold_hba1c_gap CLUSTER BY (patient_id) AS
WITH last_a1c AS (
  SELECT patient_id, CAST(observation_ts AS DATE) AS last_hba1c_date, try_cast(value AS DOUBLE) AS last_hba1c_value
  FROM caregenie.caregenie.silver_observations
  WHERE code = '4548-4'
  QUALIFY row_number() OVER (PARTITION BY patient_id ORDER BY observation_ts DESC) = 1
)
SELECT
  p.patient_id,
  p.clinic,
  a.last_hba1c_date,
  a.last_hba1c_value,
  CASE WHEN a.last_hba1c_date IS NULL THEN NULL
       ELSE CAST(floor(months_between(current_date(), a.last_hba1c_date)) AS INT) END AS months_since_last_hba1c,
  (a.last_hba1c_date IS NULL OR months_between(current_date(), a.last_hba1c_date) > 12) AS is_overdue,
  a.last_hba1c_date IS NULL AS never_tested,
  current_date() AS as_of_date
FROM caregenie.caregenie.gold_patient_panel p
LEFT JOIN last_a1c a USING (patient_id)
WHERE p.is_diabetic AND NOT p.is_deceased;

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.gold_guidelines
TBLPROPERTIES (delta.enableChangeDataFeed = true) AS
SELECT * FROM VALUES
  ('G001', 'HbA1c monitoring interval', 'diabetes',
   'FICTIONAL GUIDELINE: Adults with diabetes whose HbA1c is at goal should have HbA1c measured at least every 12 months. A patient with no HbA1c result in the last 12 months has an open care gap.'),
  ('G002', 'HbA1c monitoring when above goal', 'diabetes',
   'FICTIONAL GUIDELINE: When the most recent HbA1c is 8.0 percent or higher, or therapy has changed, repeat HbA1c every 3 to 6 months.'),
  ('G003', 'Prediabetes is not diabetes', 'diabetes',
   'FICTIONAL GUIDELINE: A prediabetes diagnosis does not place a patient in the diabetes care-gap cohort. Prediabetes follow-up uses a separate annual screening pathway.'),
  ('G004', 'Outreach for overdue HbA1c', 'outreach',
   'FICTIONAL GUIDELINE: For overdue HbA1c, contact the patient by their preferred channel and offer a lab visit. After two unanswered attempts, escalate to the care coordinator.'),
  ('G005', 'Blood pressure follow-up', 'hypertension',
   'FICTIONAL GUIDELINE: Adults with hypertension should have blood pressure checked at every visit and a medication review at least once a year.'),
  ('G006', 'Combined diabetes and hypertension', 'comorbidity',
   'FICTIONAL GUIDELINE: Patients with both diabetes and hypertension are high priority for outreach when either monitoring interval is overdue.'),
  ('G007', 'Deceased patients', 'outreach',
   'FICTIONAL GUIDELINE: Deceased patients are excluded from all care-gap lists and outreach queues.'),
  ('G008', 'Data currency', 'data',
   'FICTIONAL GUIDELINE: Care-gap status is calculated as of the table refresh date. Always state the as-of date when reporting an overdue count.')
AS t(guideline_id, title, topic, content);

-- COMMAND ----------

CREATE OR REPLACE TABLE caregenie.caregenie.gold_encounter_chunks
TBLPROPERTIES (delta.enableChangeDataFeed = true) AS
WITH procs AS (
  SELECT encounter_id, array_join(collect_set(description), '; ') AS procedures
  FROM caregenie.caregenie.silver_procedures GROUP BY encounter_id
), conds AS (
  SELECT encounter_id, array_join(collect_set(description), '; ') AS diagnoses
  FROM caregenie.caregenie.silver_conditions GROUP BY encounter_id
)
SELECT
  e.encounter_id AS chunk_id,
  e.patient_id,
  p.clinic,
  CAST(e.start_ts AS DATE) AS encounter_date,
  concat_ws(' ',
    concat('Synthetic encounter on ', CAST(CAST(e.start_ts AS DATE) AS STRING), ' (', e.encounter_class, ') at ', coalesce(p.clinic, 'unknown clinic'), '.'),
    concat('Visit: ', e.description, '.'),
    CASE WHEN e.reason_description IS NOT NULL THEN concat('Reason: ', e.reason_description, '.') END,
    CASE WHEN c.diagnoses IS NOT NULL THEN concat('Diagnosed: ', c.diagnoses, '.') END,
    CASE WHEN pr.procedures IS NOT NULL THEN concat('Procedures: ', pr.procedures, '.') END
  ) AS chunk_text
FROM caregenie.caregenie.silver_encounters e
JOIN caregenie.caregenie.gold_patient_panel p ON p.patient_id = e.patient_id
LEFT JOIN procs pr ON pr.encounter_id = e.encounter_id
LEFT JOIN conds c ON c.encounter_id = e.encounter_id
WHERE p.is_diabetic OR p.has_hypertension;

-- COMMAND ----------

COMMENT ON TABLE caregenie.caregenie.gold_patient_panel IS 'One row per synthetic patient (Synthea, not real people) with cohort flags. is_diabetic means a Diabetes diagnosis (SNOMED 44054006); Prediabetes is NOT included. clinic is the organization of the most recent encounter. Use for cohort sizes and filters. Contains no direct PII.';
COMMENT ON TABLE caregenie.caregenie.gold_hba1c_gap IS 'One row per living diabetic patient with the HbA1c care-gap status. is_overdue is true when the last HbA1c (LOINC 4548-4) is more than 12 months before as_of_date, or when the patient has never been tested. Use this table to answer which diabetic patients are overdue for HbA1c. Synthetic data.';
COMMENT ON TABLE caregenie.caregenie.gold_guidelines IS 'FICTIONAL care guideline snippets for a learning project. Not real medical advice. One row per guideline; content is the retrievable text.';
COMMENT ON TABLE caregenie.caregenie.gold_encounter_chunks IS 'One short text narrative per encounter for diabetic or hypertensive synthetic patients, built for semantic search over visit history. chunk_text is the retrievable text; contains no names or direct PII.';

-- COMMAND ----------

ALTER TABLE caregenie.caregenie.gold_patient_panel ALTER COLUMN is_diabetic COMMENT 'True if the patient has a Diabetes diagnosis (SNOMED 44054006). Prediabetes does not count';
ALTER TABLE caregenie.caregenie.gold_patient_panel ALTER COLUMN has_hypertension COMMENT 'True if the patient has a Hypertension diagnosis (SNOMED 59621000)';
ALTER TABLE caregenie.caregenie.gold_patient_panel ALTER COLUMN clinic COMMENT 'Name of the organization of the patient''s most recent encounter';
ALTER TABLE caregenie.caregenie.gold_patient_panel ALTER COLUMN age_years COMMENT 'Age in whole years as of as_of_date, or at death. Based on synthetic dates, shifted +2374 days';
ALTER TABLE caregenie.caregenie.gold_patient_panel ALTER COLUMN as_of_date COMMENT 'Date this table was built; all age and interval calculations are relative to it';
ALTER TABLE caregenie.caregenie.gold_hba1c_gap ALTER COLUMN last_hba1c_date COMMENT 'Date of the most recent HbA1c result; NULL if never tested. Synthetic dates, shifted +2374 days';
ALTER TABLE caregenie.caregenie.gold_hba1c_gap ALTER COLUMN last_hba1c_value COMMENT 'Most recent HbA1c result, in percent';
ALTER TABLE caregenie.caregenie.gold_hba1c_gap ALTER COLUMN months_since_last_hba1c COMMENT 'Whole months between the last HbA1c and as_of_date; NULL if never tested';
ALTER TABLE caregenie.caregenie.gold_hba1c_gap ALTER COLUMN is_overdue COMMENT 'True if the last HbA1c is more than 12 months old or the patient was never tested. This is the care-gap flag';
ALTER TABLE caregenie.caregenie.gold_hba1c_gap ALTER COLUMN never_tested COMMENT 'True if the patient has no HbA1c result at all';
ALTER TABLE caregenie.caregenie.gold_hba1c_gap ALTER COLUMN as_of_date COMMENT 'Date this table was built; the 12-month threshold is measured to this date';
ALTER TABLE caregenie.caregenie.gold_guidelines ALTER COLUMN content COMMENT 'FICTIONAL guideline text, not medical advice';
ALTER TABLE caregenie.caregenie.gold_encounter_chunks ALTER COLUMN chunk_text COMMENT 'Natural-language summary of one synthetic encounter; embed and search this column';

-- COMMAND ----------

ALTER TABLE caregenie.caregenie.gold_patient_panel SET TAGS ('certified' = 'true');
ALTER TABLE caregenie.caregenie.gold_hba1c_gap SET TAGS ('certified' = 'true');
ALTER TABLE caregenie.caregenie.gold_guidelines SET TAGS ('certified' = 'true');
ALTER TABLE caregenie.caregenie.gold_encounter_chunks SET TAGS ('certified' = 'true');

-- COMMAND ----------

SELECT (SELECT count(*) FROM caregenie.caregenie.gold_patient_panel) patients,
       (SELECT count(*) FROM caregenie.caregenie.gold_patient_panel WHERE is_diabetic) diabetic,
       (SELECT count(*) FROM caregenie.caregenie.gold_hba1c_gap) in_gap_table,
       (SELECT count(*) FROM caregenie.caregenie.gold_hba1c_gap WHERE is_overdue) overdue,
       (SELECT count(*) FROM caregenie.caregenie.gold_hba1c_gap WHERE never_tested) never_tested,
       (SELECT count(*) FROM caregenie.caregenie.gold_guidelines) guidelines,
       (SELECT count(*) FROM caregenie.caregenie.gold_encounter_chunks) chunks;
