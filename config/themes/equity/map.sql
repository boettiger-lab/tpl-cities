-- Map: CalEnviroScreen 5.0 percentile for each census tract in the area.
WITH aoi10 AS MATERIALIZED ({{AOI10}}),
hit AS MATERIALIZED (
  SELECT c._cng_fid, any_value(c.tract) AS tract, any_value(c.CIscore_Pctl) AS pctl,
         COUNT(DISTINCT c.h10) AS cells_in
  FROM read_parquet('s3://public-calenviroscreen/calenviroscreen-5-0/ces5/hex/h0=*/data_0.parquet') c
  JOIN aoi10 a ON c.h0 = a.h0 AND c.h10 = a.h10
  GROUP BY c._cng_fid
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-calenviroscreen/calenviroscreen-5-0/ces5/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi10) AND _cng_fid IN (SELECT _cng_fid FROM hit)
  GROUP BY _cng_fid
)
SELECT lpad(CAST(CAST(tract AS BIGINT) AS VARCHAR), 11, '0') AS GEOID, round(pctl, 1) AS value
FROM hit JOIN tot USING (_cng_fid)
WHERE cells_in >= 0.5 * cells_all AND pctl IS NOT NULL AND NOT isnan(pctl)
