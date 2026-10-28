-- Silver date-shift checks (expect gap_mismatches = 0, and silver row counts == bronze row counts).
WITH b AS (
  SELECT PATIENT p, CAST(DATE AS DATE) d,
         datediff(CAST(DATE AS DATE), lag(CAST(DATE AS DATE)) OVER (PARTITION BY PATIENT ORDER BY DATE)) gap
  FROM caregenie.caregenie.bronze_observations WHERE CODE = '4548-4'
), s AS (
  SELECT patient_id p, CAST(observation_ts AS DATE) d,
         datediff(CAST(observation_ts AS DATE), lag(CAST(observation_ts AS DATE)) OVER (PARTITION BY patient_id ORDER BY observation_ts)) gap
  FROM caregenie.caregenie.silver_observations WHERE code = '4548-4'
)
SELECT count(*) AS hba1c_rows, count(DISTINCT b.p) AS patients,
       sum(CASE WHEN b.gap <=> s.gap THEN 0 ELSE 1 END) AS gap_mismatches
FROM (SELECT p, row_number() OVER (PARTITION BY p ORDER BY d) rn, gap FROM b) b
JOIN (SELECT p, row_number() OVER (PARTITION BY p ORDER BY d) rn, gap FROM s) s USING (p, rn);
