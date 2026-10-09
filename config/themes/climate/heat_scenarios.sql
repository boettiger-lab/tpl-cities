-- BIO5 warming by emissions scenario and period (5-model median).
WITH aoi AS MATERIALIZED ({{AOI}}),
land AS (
  SELECT e.h0, e.h8, e.land_area_km2 AS wt
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet') e
  JOIN aoi a ON e.h0 = a.h0 AND e.h8 = a.h8
),
base AS (
  SELECT b.h0, b.h8, b.bio5
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/baseline-1981-2010/hex/h0=*/data_0.parquet') b
  JOIN aoi a ON b.h0 = a.h0 AND b.h8 = a.h8
  WHERE NOT isnan(b.bio5)
),
fut AS (
  SELECT 'ssp126' AS scenario, '2041-2070' AS period, f.h0, f.h8, f.bio5_median
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/ssp126-2041-2070/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  UNION ALL
  SELECT 'ssp370' AS scenario, '2041-2070' AS period, f.h0, f.h8, f.bio5_median
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/ssp370-2041-2070/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  UNION ALL
  SELECT 'ssp585' AS scenario, '2041-2070' AS period, f.h0, f.h8, f.bio5_median
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/ssp585-2041-2070/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  UNION ALL
  SELECT 'ssp126' AS scenario, '2071-2100' AS period, f.h0, f.h8, f.bio5_median
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/ssp126-2071-2100/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  UNION ALL
  SELECT 'ssp370' AS scenario, '2071-2100' AS period, f.h0, f.h8, f.bio5_median
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/ssp370-2071-2100/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  UNION ALL
  SELECT 'ssp585' AS scenario, '2071-2100' AS period, f.h0, f.h8, f.bio5_median
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/ssp585-2071-2100/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
)
SELECT CASE f.scenario WHEN 'ssp126' THEN 'Low (SSP1-2.6)' WHEN 'ssp370' THEN 'Medium-high (SSP3-7.0)' ELSE 'Very high (SSP5-8.5)' END AS scenario,
       SUM(l.wt * (f.bio5_median - b.bio5)) FILTER (WHERE f.period = '2041-2070') / SUM(l.wt) FILTER (WHERE f.period = '2041-2070') AS mid_century_c,
       SUM(l.wt * (f.bio5_median - b.bio5)) FILTER (WHERE f.period = '2071-2100') / SUM(l.wt) FILTER (WHERE f.period = '2071-2100') AS end_century_c
FROM fut f
JOIN base b ON f.h0 = b.h0 AND f.h8 = b.h8
JOIN land l ON f.h0 = l.h0 AND f.h8 = l.h8
WHERE NOT isnan(f.bio5_median)
GROUP BY f.scenario
ORDER BY f.scenario

