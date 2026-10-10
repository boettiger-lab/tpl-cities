-- Map: CalEnviroScreen 5.0 percentile of every census tract the area touches.
WITH aoi10 AS MATERIALIZED ({{AOI10}})
SELECT DISTINCT lpad(CAST(CAST(c.tract AS BIGINT) AS VARCHAR), 11, '0') AS GEOID, round(c.CIscore_Pctl, 1) AS value
FROM read_parquet('s3://public-calenviroscreen/calenviroscreen-5-0/ces5/hex/h0=*/data_0.parquet') c
JOIN aoi10 a ON c.h0 = a.h0 AND c.h10 = a.h10
WHERE c.CIscore_Pctl IS NOT NULL AND NOT isnan(c.CIscore_Pctl)
