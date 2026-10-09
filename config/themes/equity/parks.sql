-- Residents without a park within 1/2 mile (SCORP 2020 Park Access Tool).
-- The no-access polygons carry whole-block-group population, so population is
-- re-apportioned here: each ACS 2020-24 block group's people are spread evenly
-- over its res-10 cells, and we count those in no-access cells.
-- Also: share of residents in park-poor tracts (< 3 park acres per 1,000).
WITH aoi10 AS MATERIALIZED ({{AOI10}}),
bgc AS MATERIALIZED (
  SELECT b._cng_fid, b.h0, b.h10, b.TotPop
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet') b
  JOIN aoi10 a ON b.h0 = a.h0 AND b.h10 = a.h10
),
np AS (
  SELECT DISTINCT n.h0, n.h10
  FROM read_parquet('s3://public-parks/park-access-2020/no-park-access/hex/h0=*/data_0.parquet') n
  JOIN aoi10 a ON n.h0 = a.h0 AND n.h10 = a.h10
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi10) AND _cng_fid IN (SELECT DISTINCT _cng_fid FROM bgc)
  GROUP BY _cng_fid
),
per_bg AS (
  SELECT bgc._cng_fid, any_value(bgc.TotPop) AS pop,
         COUNT(DISTINCT bgc.h10) AS cells_in, COUNT(DISTINCT np.h10) AS cells_np
  FROM bgc LEFT JOIN np ON bgc.h0 = np.h0 AND bgc.h10 = np.h10
  GROUP BY bgc._cng_fid
),
nopark AS (
  SELECT SUM(pop * cells_in / cells_all) AS pop_apportioned,
         SUM(pop * cells_np / cells_all) AS pop_no_park
  FROM per_bg JOIN tot USING (_cng_fid)
  WHERE pop IS NOT NULL
),
ppk_hit AS MATERIALIZED (
  SELECT p._cng_fid, any_value(p.TotPop) AS pop, any_value(p.PPK_tract) AS ppk, COUNT(DISTINCT p.h10) AS cells_in
  FROM read_parquet('s3://public-parks/park-access-2020/tract-acres-per-thousand/hex/h0=*/data_0.parquet') p
  JOIN aoi10 a ON p.h0 = a.h0 AND p.h10 = a.h10
  GROUP BY p._cng_fid
),
ppk_tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-parks/park-access-2020/tract-acres-per-thousand/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi10) AND _cng_fid IN (SELECT _cng_fid FROM ppk_hit)
  GROUP BY _cng_fid
),
ppk AS (
  SELECT COALESCE(SUM(pop) FILTER (WHERE ppk < 3), 0) / NULLIF(SUM(pop), 0) AS frac_pop_park_poor
  FROM ppk_hit JOIN ppk_tot USING (_cng_fid)
  WHERE cells_in >= 0.5 * cells_all
)
SELECT n.pop_no_park, n.pop_no_park / NULLIF(n.pop_apportioned, 0) AS frac_pop_no_park,
       p.frac_pop_park_poor
FROM nopark n, ppk p
