-- CHELSA 2.1: change in max temperature of the warmest month (BIO5), baseline
-- 1981-2010 vs SSP3-7.0 2041-2070 (median of 5 climate models).
WITH aoi AS MATERIALIZED ({{AOI}}),
land AS (
  SELECT e.h0, e.h8, e.land_area_km2 AS wt
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet') e
  JOIN aoi a ON e.h0 = a.h0 AND e.h8 = a.h8
),
prot AS (
  SELECT w.h0, w.h8, w.w1 + w.w2 AS pw
  FROM read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights-res8/h0=*/data_0.parquet') w
  JOIN aoi a ON w.h0 = a.h0 AND w.h8 = a.h8
),
base AS (
  SELECT b.h0, b.h8, b.bio1, b.bio5
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/baseline-1981-2010/hex/h0=*/data_0.parquet') b
  JOIN aoi a ON b.h0 = a.h0 AND b.h8 = a.h8
),
fut AS (   -- default scenario: SSP3-7.0, 2041-2070, 5-GCM median
  SELECT f.h0, f.h8, f.bio1_median, f.bio5_median, f.bio5_min, f.bio5_max
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/ssp370-2041-2070/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
),
c AS (
  SELECT l.wt, COALESCE(p.pw, 0) AS pw,
         b.bio5 AS bio5_base, f.bio5_median AS bio5_fut,
         f.bio5_median - b.bio5 AS d5,
         f.bio5_min    - b.bio5 AS d5_lo,
         f.bio5_max    - b.bio5 AS d5_hi,
         f.bio1_median - b.bio1 AS d1
  FROM land l
  JOIN base b ON l.h0 = b.h0 AND l.h8 = b.h8
  JOIN fut  f ON l.h0 = f.h0 AND l.h8 = f.h8
  LEFT JOIN prot p ON l.h0 = p.h0 AND l.h8 = p.h8
  WHERE NOT isnan(b.bio5) AND NOT isnan(f.bio5_median)
)
SELECT
  SUM(wt * bio5_base) / SUM(wt)  AS bio5_baseline_c,
  SUM(wt * bio5_fut)  / SUM(wt)  AS bio5_future_c,
  SUM(wt * d5) / SUM(wt)         AS bio5_increase_c,
  MIN(d5)                        AS bio5_increase_min_c,
  MAX(d5)                        AS bio5_increase_max_c,
  SUM(wt * d5_lo) / SUM(wt)      AS bio5_increase_model_lo_c,
  SUM(wt * d5_hi) / SUM(wt)      AS bio5_increase_model_hi_c,
  SUM(wt * d1) / SUM(wt)         AS bio1_increase_c,
  SUM(wt * pw * d5)       / NULLIF(SUM(wt * pw), 0)       AS bio5_increase_protected_c,
  SUM(wt * (1 - pw) * d5) / NULLIF(SUM(wt * (1 - pw)), 0) AS bio5_increase_unprotected_c,
  COUNT(*) AS n_cells
FROM c
