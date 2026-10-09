-- Population and income from ACS 2020-2024 block groups. A block group counts
-- toward the area when at least half of its res-10 cells fall inside it.
WITH aoi10 AS MATERIALIZED ({{AOI10}}),
hit AS MATERIALIZED (
  SELECT b._cng_fid, any_value(b.TotPop) AS pop, any_value(b.MHHI) AS mhhi,
         COUNT(DISTINCT b.h10) AS cells_in
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet') b
  JOIN aoi10 a ON b.h0 = a.h0 AND b.h10 = a.h10
  GROUP BY b._cng_fid
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi10) AND _cng_fid IN (SELECT _cng_fid FROM hit)
  GROUP BY _cng_fid
),
bg AS (
  SELECT pop, mhhi FROM hit JOIN tot USING (_cng_fid)
  WHERE cells_in >= 0.5 * cells_all
)
SELECT COUNT(*) AS n_blockgroups,
       SUM(pop) AS population,
       SUM(mhhi * pop) FILTER (WHERE mhhi IS NOT NULL) / SUM(pop) FILTER (WHERE mhhi IS NOT NULL) AS income
FROM bg
