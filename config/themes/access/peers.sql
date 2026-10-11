-- Precompute only (scripts/precompute.mjs peers): the access.sql "All
-- residents" row for every jurisdiction of one type at once, used to rank a
-- place among its peers. {{CELLS10}} yields (id, h0, h10) for every feature.
-- Formulas must match access.sql.
WITH cells AS MATERIALIZED ({{CELLS10}}),
bgc AS MATERIALIZED (
  SELECT DISTINCT c.id, b._cng_fid, b.h0, b.h10, b.TotPop, b.MHHI
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet') b
  JOIN cells c ON b.h0 = c.h0 AND b.h10 = c.h10
),
sv AS MATERIALIZED (
  SELECT s.h0, s.h10, MAX(s.park_size_acres) AS max_acres
  FROM read_parquet('s3://public-tpl/parkserve-2025/service-areas/hex/h0=*/data_0.parquet') s
  SEMI JOIN (SELECT DISTINCT h0, h10 FROM cells) c ON s.h0 = c.h0 AND s.h10 = c.h10
  GROUP BY s.h0, s.h10
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM cells) AND _cng_fid IN (SELECT DISTINCT _cng_fid FROM bgc)
  GROUP BY _cng_fid
),
per AS (
  SELECT bgc.id, bgc._cng_fid, any_value(bgc.TotPop) AS pop, any_value(bgc.MHHI) AS mhhi,
         COUNT(*) AS cells_in,
         COUNT(sv.h10) AS cells_served,
         COUNT(sv.h10) FILTER (WHERE sv.max_acres >= 10) AS cells_big
  FROM bgc LEFT JOIN sv ON bgc.h0 = sv.h0 AND bgc.h10 = sv.h10
  GROUP BY bgc.id, bgc._cng_fid
),
bg AS (
  SELECT id, pop * cells_in / cells_all AS p,
         pop * cells_served / cells_all AS s,
         pop * cells_big / cells_all AS sb,
         CASE WHEN mhhi IS NULL THEN NULL WHEN mhhi < 80000 THEN 1 ELSE 3 END AS band
  FROM per JOIN tot USING (_cng_fid)
  WHERE pop > 0
),
total AS (
  SELECT id, SUM(p) AS pop, SUM(s) AS served, SUM(sb) AS served_big,
         SUM(s) FILTER (WHERE band <= 2) / NULLIF(SUM(p) FILTER (WHERE band <= 2), 0) AS frac_low,
         SUM(s) FILTER (WHERE band >= 3) / NULLIF(SUM(p) FILTER (WHERE band >= 3), 0) AS frac_high
  FROM bg GROUP BY id
),
parts AS (
  SELECT *, 100 * served / NULLIF(pop, 0) AS reach,
         100 * served_big / NULLIF(pop, 0) AS room,
         CASE WHEN frac_low IS NULL OR frac_high IS NULL THEN NULL
              WHEN frac_high = 0 THEN 100.0
              ELSE 100 * LEAST(1, frac_low / frac_high) END AS fairness
  FROM total
)
SELECT id, pop, reach, room, fairness,
       (reach + room) / 2 * COALESCE(fairness, 100) / 100 AS score
FROM parts
ORDER BY id
