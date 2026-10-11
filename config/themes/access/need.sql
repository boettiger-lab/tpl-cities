-- Residents beyond a 10-minute walk of any park, by TPL's park-need priority
-- for the area they live in (ParkServe 2025 "priority areas for new parks",
-- place-based). TPL ranks need within each city (very high / high / moderate),
-- so levels compare places within a city better than across cities. Areas
-- outside ParkServe's mapped communities (mostly rural and unincorporated
-- land) have no rank. Residents are apportioned as in access.sql.
WITH aoi10 AS MATERIALIZED ({{AOI10}}),
bgc AS MATERIALIZED (
  SELECT DISTINCT b._cng_fid, b.h0, b.h10, b.TotPop
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet') b
  JOIN aoi10 a ON b.h0 = a.h0 AND b.h10 = a.h10
),
sv AS MATERIALIZED (
  SELECT DISTINCT s.h0, s.h10
  FROM read_parquet('s3://public-tpl/parkserve-2025/service-areas/hex/h0=*/data_0.parquet') s
  JOIN aoi10 a ON s.h0 = a.h0 AND s.h10 = a.h10
),
pr AS MATERIALIZED (
  SELECT p.h0, p.h10, MAX(p.parkrank) AS rank
  FROM read_parquet('s3://public-tpl/parkserve-2025/priority-areas-place/hex/h0=*/data_0.parquet') p
  JOIN aoi10 a ON p.h0 = a.h0 AND p.h10 = a.h10
  GROUP BY p.h0, p.h10
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi10) AND _cng_fid IN (SELECT DISTINCT _cng_fid FROM bgc)
  GROUP BY _cng_fid
),
unserved AS (
  SELECT COALESCE(pr.rank, 0) AS rank, bgc.TotPop / tot.cells_all AS w
  FROM bgc
  JOIN tot USING (_cng_fid)
  LEFT JOIN sv ON bgc.h0 = sv.h0 AND bgc.h10 = sv.h10
  LEFT JOIN pr ON bgc.h0 = pr.h0 AND bgc.h10 = pr.h10
  WHERE sv.h10 IS NULL AND bgc.TotPop > 0
),
lv AS (SELECT * FROM (VALUES (3, 'Very high'), (2, 'High'), (1, 'Moderate'), (0, 'No TPL rank')) t(rank, priority))
SELECT lv.priority, lv.rank, COALESCE(SUM(u.w), 0) AS pop,
       COALESCE(SUM(u.w), 0) / NULLIF(SUM(SUM(u.w)) OVER (), 0) AS frac
FROM lv LEFT JOIN unserved u USING (rank)
GROUP BY lv.priority, lv.rank
ORDER BY lv.rank DESC
