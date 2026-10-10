-- Who lives within reach. Every source polygon (tract or block group) is
-- apportioned by the share of its res-10 cells inside the area, so partially
-- covered units count partially (population assumed even within a unit).
--   CalEnviroScreen 5.0 (draft) percentile, population-weighted, by tract
--   DWR 2023 disadvantaged-community block groups (income-based)
--   ACS 2020-24 median household income, population-weighted block-group mean
-- Returns population by CES decile (10 rows) with summary columns repeated.
WITH aoi10 AS MATERIALIZED ({{AOI10}}),
ces_hit AS MATERIALIZED (
  SELECT c._cng_fid, any_value(c.CIscore_Pctl) AS pctl, any_value(c.Population) AS pop, COUNT(DISTINCT c.h10) AS cells_in
  FROM read_parquet('s3://public-calenviroscreen/calenviroscreen-5-0/ces5/hex/h0=*/data_0.parquet') c
  JOIN aoi10 a ON c.h0 = a.h0 AND c.h10 = a.h10
  GROUP BY c._cng_fid
),
ces_tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-calenviroscreen/calenviroscreen-5-0/ces5/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi10) AND _cng_fid IN (SELECT _cng_fid FROM ces_hit)
  GROUP BY _cng_fid
),
ces AS MATERIALIZED (
  SELECT pctl, pop * cells_in / cells_all AS pop
  FROM ces_hit JOIN ces_tot USING (_cng_fid)
  WHERE pctl IS NOT NULL AND NOT isnan(pctl)
),
bg_hit AS MATERIALIZED (
  SELECT b._cng_fid, any_value(b.TotPop) AS pop, any_value(b.MHHI) AS mhhi, COUNT(DISTINCT b.h10) AS cells_in
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet') b
  JOIN aoi10 a ON b.h0 = a.h0 AND b.h10 = a.h10
  GROUP BY b._cng_fid
),
bg_tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi10) AND _cng_fid IN (SELECT _cng_fid FROM bg_hit)
  GROUP BY _cng_fid
),
bg AS (SELECT mhhi, pop * cells_in / cells_all AS pop FROM bg_hit JOIN bg_tot USING (_cng_fid)),
dac_hit AS MATERIALIZED (
  SELECT d._cng_fid, any_value(d.DAC23) AS dac, any_value(d.Pop23) AS pop, COUNT(DISTINCT d.h10) AS cells_in
  FROM read_parquet('s3://public-ca-dac/dac-2023/blockgroup/hex/h0=*/data_0.parquet') d
  JOIN aoi10 a ON d.h0 = a.h0 AND d.h10 = a.h10
  GROUP BY d._cng_fid
),
dac_tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-ca-dac/dac-2023/blockgroup/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi10) AND _cng_fid IN (SELECT _cng_fid FROM dac_hit)
  GROUP BY _cng_fid
),
dac AS (SELECT dac = 'Y' AS is_dac, pop * cells_in / cells_all AS pop FROM dac_hit JOIN dac_tot USING (_cng_fid)),
summary AS (
  SELECT (SELECT SUM(pctl * pop) / NULLIF(SUM(pop), 0) FROM ces) AS ces_pctl,
         (SELECT COALESCE(SUM(pop) FILTER (WHERE pctl >= 75), 0) / NULLIF(SUM(pop), 0) FROM ces) AS frac_pop_ces_top25,
         (SELECT SUM(mhhi * pop) FILTER (WHERE mhhi IS NOT NULL) / NULLIF(SUM(pop) FILTER (WHERE mhhi IS NOT NULL), 0) FROM bg) AS income,
         (SELECT COALESCE(SUM(pop) FILTER (WHERE is_dac), 0) / NULLIF(SUM(pop), 0) FROM dac) AS frac_pop_dac
),
bins AS (SELECT LEAST(CAST(floor(pctl / 10) AS INT), 9) * 10 AS lo, SUM(pop) AS pop FROM ces GROUP BY 1)
SELECT CAST(r.range AS VARCHAR) || '–' || CAST(r.range + 10 AS VARCHAR) || (CASE WHEN r.range = 0 THEN ' (least burdened)' WHEN r.range = 90 THEN ' (most burdened)' ELSE '' END) AS decile,
       COALESCE(b.pop, 0) / NULLIF((SELECT SUM(pop) FROM ces), 0) AS frac_pop,
       s.*
FROM range(0, 100, 10) r
CROSS JOIN summary s
LEFT JOIN bins b ON b.lo = r.range
ORDER BY r.range DESC
