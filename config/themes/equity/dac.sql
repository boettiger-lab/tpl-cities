-- Disadvantaged-community (DAC) tracts (DWR 2023, income-based: tract median
-- household income < 80% of statewide) vs other tracts: population, land,
-- and protected (GAP 1-2) land per 1,000 residents. Tracts count toward the
-- area by majority of their res-10 cells; land is masked to the CA land grid.
WITH aoi10 AS MATERIALIZED ({{AOI10}}),
dacc AS MATERIALIZED (
  SELECT d._cng_fid, d.h0, d.h10, d.DAC23 = 'Y' AS dac, d.Pop23
  FROM read_parquet('s3://public-ca-dac/dac-2023/tract/hex/h0=*/data_0.parquet') d
  JOIN aoi10 a ON d.h0 = a.h0 AND d.h10 = a.h10
),
tr AS (
  SELECT _cng_fid, any_value(dac) AS dac, any_value(Pop23) AS pop, COUNT(DISTINCT h10) AS cells_in
  FROM dacc GROUP BY _cng_fid
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-ca-dac/dac-2023/tract/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi10) AND _cng_fid IN (SELECT _cng_fid FROM tr)
  GROUP BY _cng_fid
),
pop AS (
  SELECT dac, COUNT(*) AS n_tracts, SUM(pop) AS pop
  FROM tr JOIN tot USING (_cng_fid)
  WHERE cells_in >= 0.5 * cells_all
  GROUP BY dac
),
cells AS (
  SELECT DISTINCT c.h0, c.h10, c.dac
  FROM dacc c
  SEMI JOIN read_parquet('s3://public-ca30x30/ecoregion/hex/h0=*/data_0.parquet') e
    ON e.h0 = c.h0 AND e.h10 = c.h10
),
land AS (
  SELECT c.dac,
         SUM(h3_cell_area(c.h10, 'km^2')) * 247.105 AS acres,
         SUM(h3_cell_area(c.h10, 'km^2') * COALESCE(w.w1 + w.w2, 0)) * 247.105 AS gap12_acres
  FROM cells c
  LEFT JOIN read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights/h0=*/data_0.parquet') w
    ON w.h0 = c.h0 AND w.h10 = c.h10
  GROUP BY c.dac
),
g AS (
  SELECT CASE WHEN dac THEN 'DAC tracts' ELSE 'Other tracts' END AS grp,
         COALESCE(p.n_tracts, 0) AS n_tracts, COALESCE(p.pop, 0) AS pop,
         COALESCE(l.acres, 0) AS acres, COALESCE(l.gap12_acres, 0) AS gap12_acres
  FROM (SELECT * FROM (VALUES (true), (false)) v(dac)) k
  LEFT JOIN pop p USING (dac)
  LEFT JOIN land l USING (dac)
)
SELECT grp, n_tracts, pop, acres, gap12_acres,
       pop / NULLIF(SUM(pop) OVER (), 0) AS frac_pop,
       acres / NULLIF(SUM(acres) OVER (), 0) AS frac_land,
       gap12_acres / NULLIF(SUM(gap12_acres) OVER (), 0) AS frac_gap12,
       1000 * gap12_acres / NULLIF(pop, 0) AS gap12_acres_per_1000,
       gap12_acres / NULLIF(acres, 0) AS frac_protected
FROM g
ORDER BY grp
