-- Databricks notebook source
-- MAGIC %md
-- MAGIC # 04 Unity Catalog function tools
-- MAGIC UC functions are governed, discoverable tools an agent can call. The `COMMENT` on the function and on each
-- MAGIC parameter IS the tool description the model reads, so write it for a model.
-- MAGIC Read tools are SQL table functions. The write tool is a SQL stored procedure (SQL UDFs are read-only).
-- MAGIC All data is synthetic. Outputs contain no direct PII.

-- COMMAND ----------

CREATE TABLE IF NOT EXISTS caregenie.caregenie.outreach_queue (
  queue_id STRING COMMENT 'Unique id of the outreach request',
  patient_id STRING COMMENT 'Synthetic patient id',
  channel STRING COMMENT 'Contact channel: phone, sms, email or mail',
  reason STRING COMMENT 'Why outreach was requested',
  requested_by STRING COMMENT 'Audit: the Databricks user who made the request',
  requested_at TIMESTAMP COMMENT 'Audit: when the request was made',
  status STRING COMMENT 'queued, contacted or closed'
) COMMENT 'Outreach requests created by agent or human. Append-only audit trail; synthetic patients only.'
CLUSTER BY (patient_id);

-- COMMAND ----------

CREATE OR REPLACE FUNCTION caregenie.caregenie.overdue_hba1c_patients(
  clinic_name STRING DEFAULT NULL COMMENT 'Exact clinic name to filter on, or NULL for all clinics',
  months INT DEFAULT 12 COMMENT 'A patient is listed when their last HbA1c is more than this many whole months old, or they were never tested'
)
RETURNS TABLE (patient_id STRING, clinic STRING, last_hba1c_date DATE, months_since_last_hba1c INT, last_hba1c_value DOUBLE)
COMMENT 'EXACT LOOKUP. Lists living diabetic patients (not prediabetic) whose HbA1c is overdue. Use for questions like which patients are overdue, how many, or at which clinic. Do not use for guideline questions or for one patient''s history.'
RETURN
  SELECT g.patient_id, g.clinic, g.last_hba1c_date, g.months_since_last_hba1c, g.last_hba1c_value
  FROM caregenie.caregenie.gold_hba1c_gap g
  WHERE (overdue_hba1c_patients.clinic_name IS NULL OR g.clinic = overdue_hba1c_patients.clinic_name)
    AND (g.never_tested OR g.months_since_last_hba1c > overdue_hba1c_patients.months);

-- COMMAND ----------

CREATE OR REPLACE FUNCTION caregenie.caregenie.patient_summary(
  patient_id STRING COMMENT 'Synthetic patient id (a UUID string)'
)
RETURNS TABLE (patient_id STRING, gender STRING, age_years INT, clinic STRING, is_diabetic BOOLEAN, has_hypertension BOOLEAN,
               is_deceased BOOLEAN, last_hba1c_date DATE, last_hba1c_value DOUBLE, hba1c_overdue BOOLEAN)
COMMENT 'EXACT LOOKUP. Returns the cohort flags and HbA1c status for ONE patient id. No names or contact data. Use after a patient id is known; do not use to search for patients.'
RETURN
  SELECT p.patient_id, p.gender, p.age_years, p.clinic, p.is_diabetic, p.has_hypertension, p.is_deceased,
         g.last_hba1c_date, g.last_hba1c_value, g.is_overdue
  FROM caregenie.caregenie.gold_patient_panel p
  LEFT JOIN caregenie.caregenie.gold_hba1c_gap g ON g.patient_id = p.patient_id
  WHERE p.patient_id = patient_summary.patient_id;

-- COMMAND ----------

CREATE OR REPLACE PROCEDURE caregenie.caregenie.queue_outreach(
  IN patient_id STRING COMMENT 'Synthetic patient id to contact',
  IN channel STRING COMMENT 'One of phone, sms, email, mail',
  IN reason STRING COMMENT 'Short reason for the outreach, e.g. HbA1c overdue'
)
LANGUAGE SQL
COMMENT 'WRITE ACTION. Adds one outreach request to outreach_queue with an audit record (user and timestamp). Call only when the user explicitly asks to queue outreach. Rejects unknown patients, deceased patients and invalid channels.'
SQL SECURITY INVOKER
AS BEGIN
  DECLARE ok INT;
  SET ok = (SELECT count(*) FROM caregenie.caregenie.gold_patient_panel p WHERE p.patient_id = queue_outreach.patient_id AND NOT p.is_deceased);
  IF ok = 0 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Unknown or deceased patient'; END IF;
  IF lower(queue_outreach.channel) NOT IN ('phone', 'sms', 'email', 'mail') THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid channel'; END IF;
  INSERT INTO caregenie.caregenie.outreach_queue
  SELECT uuid(), queue_outreach.patient_id, lower(queue_outreach.channel), queue_outreach.reason, current_user(), current_timestamp(), 'queued';
END;
