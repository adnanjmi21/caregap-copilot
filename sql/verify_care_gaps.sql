-- Independent recompute of the HbA1c care gap straight from the raw CSVs in the Volume,
-- compared with gold_hba1c_gap. Synthetic data. Expect mismatches = 0 on every row.
-- as_of is taken from gold so the check is reproducible after the table was built.
WITH shift AS (SELECT shift_days FROM caregenie.caregenie.silver_date_shift),
as_of AS (SELECT max(as_of_date) AS d FROM caregenie.caregenie.gold_hba1c_gap),
raw_pat AS (
  SELECT Id AS patient_id, DEATHDATE FROM read_files('/Volumes/caregenie/caregenie/raw/synthea/patients.csv', format => 'csv', header => true)
),
raw_dm AS (
  SELECT DISTINCT PATIENT AS patient_id
  FROM read_files('/Volumes/caregenie/caregenie/raw/synthea/conditions.csv', format => 'csv', header => true)
  WHERE CODE = 44054006
),
raw_a1c AS (
  SELECT PATIENT AS patient_id, max(date_add(CAST(DATE AS DATE), (SELECT shift_days FROM shift))) AS last_date
  FROM read_files('/Volumes/caregenie/caregenie/raw/synthea/observations.csv', format => 'csv', header => true)
  WHERE CODE = '4548-4' GROUP BY PATIENT
),
expected AS (
  SELECT d.patient_id, a.last_date,
         (a.last_date IS NULL OR months_between((SELECT d FROM as_of), a.last_date) > 12) AS exp_overdue
  FROM raw_dm d JOIN raw_pat p USING (patient_id)
  LEFT JOIN raw_a1c a USING (patient_id)
  WHERE p.DEATHDATE IS NULL
)
SELECT count(*) AS cohort_rows_expected,
       (SELECT count(*) FROM caregenie.caregenie.gold_hba1c_gap) AS cohort_rows_gold,
       sum(CASE WHEN g.patient_id IS NULL THEN 1 ELSE 0 END) AS missing_in_gold,
       sum(CASE WHEN g.last_hba1c_date <=> e.last_date AND g.is_overdue = e.exp_overdue THEN 0 ELSE 1 END) AS mismatches
FROM expected e LEFT JOIN caregenie.caregenie.gold_hba1c_gap g USING (patient_id);
