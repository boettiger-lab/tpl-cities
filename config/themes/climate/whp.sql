-- Wildfire Hazard Potential 2023 (USFS): share of land in High/Very High classes.
WITH aoi AS MATERIALIZED ({{AOI}}),
whp AS (
  SELECT x.h0, x.h9, x.whp_class
  FROM read_parquet('s3://public-fire/whp-2023-classified-conus/hex/h0=*/data_0.parquet') x
  JOIN aoi a ON x.h0 = a.h0 AND x.h8 = a.h8
),
land9 AS (
  SELECT e.h0, e.h9, e.land_area_km2
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res9/h0=*/data_0.parquet') e
  JOIN aoi a ON e.h0 = a.h0 AND e.h8 = a.h8
),
prot9 AS (
  SELECT w.h0, w.h9, w.w1 + w.w2 AS pw
  FROM read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights-res9/h0=*/data_0.parquet') w
  JOIN aoi a ON w.h0 = a.h0 AND w.h8 = a.h8
),
c AS (
  SELECT l.land_area_km2 AS a, x.whp_class,
         CASE WHEN x.whp_class IN (4, 5) THEN 1 ELSE 0 END AS hi,
         COALESCE(p.pw, 0) AS pw
  FROM land9 l
  JOIN whp x ON l.h0 = x.h0 AND l.h9 = x.h9
  LEFT JOIN prot9 p ON l.h0 = p.h0 AND l.h9 = p.h9
)
SELECT
  SUM(a)                                               AS mapped_land_km2,
  SUM(a * hi) / SUM(a)                                 AS whp_high_share,          -- classes 4-5 of all mapped land (incl. non-burnable)
  SUM(a * hi) / NULLIF(SUM(a) FILTER (WHERE whp_class <= 5), 0) AS whp_high_share_burnable,
  SUM(a * hi * pw)       / NULLIF(SUM(a * pw), 0)       AS whp_high_share_protected,
  SUM(a * hi * (1 - pw)) / NULLIF(SUM(a * (1 - pw)), 0) AS whp_high_share_unprotected
FROM c
