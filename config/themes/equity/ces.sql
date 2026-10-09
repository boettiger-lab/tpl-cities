-- CalEnviroScreen 5.0 (draft) cumulative-impact percentile by tract, tracts
-- assigned by majority of res-10 cells. Returns population by CES decile
-- plus summary columns repeated on every row.
WITH aoi10 AS MATERIALIZED ({{AOI10}}),
hit AS MATERIALIZED (
  SELECT c._cng_fid, any_value(c.CIscore_Pctl) AS pctl, any_value(c.Population) AS pop,
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
),
tr AS MATERIALIZED (
  SELECT pctl, pop FROM hit JOIN tot USING (_cng_fid)
  WHERE cells_in >= 0.5 * cells_all AND pctl IS NOT NULL AND NOT isnan(pctl)
),
summary AS (
  SELECT SUM(pctl * pop) / NULLIF(SUM(pop), 0) AS ces_pctl,
         COALESCE(SUM(pop) FILTER (WHERE pctl >= 75), 0) / NULLIF(SUM(pop), 0) AS frac_pop_top25,
         SUM(pop) AS pop_scored
  FROM tr
),
bins AS (
  SELECT LEAST(CAST(floor(pctl / 10) AS INT), 9) * 10 AS lo, SUM(pop) AS pop
  FROM tr GROUP BY 1
)
SELECT CAST(r.range AS VARCHAR) || '–' || CAST(r.range + 10 AS VARCHAR) || (CASE WHEN r.range = 0 THEN ' (least burdened)' WHEN r.range = 90 THEN ' (most burdened)' ELSE '' END) AS decile,
       COALESCE(b.pop, 0) AS pop,
       COALESCE(b.pop, 0) / NULLIF(s.pop_scored, 0) AS frac_pop,
       s.ces_pctl, s.frac_pop_top25
FROM range(0, 100, 10) r
CROSS JOIN summary s
LEFT JOIN bins b ON b.lo = r.range
ORDER BY r.range DESC
