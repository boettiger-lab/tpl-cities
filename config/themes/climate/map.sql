-- Map: share of each tract in the 100-yr floodplain, 5 ft sea-level-rise zone,
-- or High/Very High wildfire hazard (any of the three).
WITH aoi AS MATERIALIZED ({{AOI}}),
tr AS (            -- 2024 CA tract res-10 cells inside the AOI
  SELECT t.GEOID, t.h0, t.h8, t.h9, t.h10, (t.ALAND + t.AWATER) / 1e6 AS tract_km2
  FROM read_parquet('s3://public-census/census-2024/tract/hex/h0=*/data_0.parquet') t
  JOIN aoi a ON t.h0 = a.h0 AND t.h8 = a.h8
  WHERE t.STATEFP = '06'
),
base AS (
  SELECT b.h0, b.h8, b.bio5
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/baseline-1981-2010/hex/h0=*/data_0.parquet') b
  JOIN aoi a ON b.h0 = a.h0 AND b.h8 = a.h8
),
fut AS (
  SELECT f.h0, f.h8, f.bio5_median
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/ssp370-2041-2070/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
),
d8 AS (
  SELECT b.h0, b.h8, f.bio5_median - b.bio5 AS d5
  FROM base b JOIN fut f ON b.h0 = f.h0 AND b.h8 = f.h8
  WHERE NOT isnan(b.bio5) AND NOT isnan(f.bio5_median)
),
fl AS (
  SELECT DISTINCT f.h0, f.h10
  FROM read_parquet('s3://public-hazard/flood-hazard/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  WHERE f.SFHA_TF = 'T'
),
slr AS (
  SELECT DISTINCT s.h0, s.h10
  FROM read_parquet('s3://public-hazard/sea-level-rise/hex/h0=*/data_0.parquet') s
  JOIN aoi a ON s.h0 = a.h0 AND s.h8 = a.h8
  WHERE s.state = 'CA'
),
burn AS (
  SELECT DISTINCT f.h0, f.h10
  FROM read_parquet('s3://public-fire/calfire-2025/firep/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  WHERE f.YEAR_ BETWEEN 2021 AND 2025
),
whp AS (
  SELECT x.h0, x.h9
  FROM read_parquet('s3://public-fire/whp-2023-classified-conus/hex/h0=*/data_0.parquet') x
  JOIN aoi a ON x.h0 = a.h0 AND x.h8 = a.h8
  WHERE x.whp_class IN (4, 5)
),
c AS (
  SELECT tr.GEOID, tr.tract_km2,
         h3_cell_area(tr.h10, 'km^2') AS a,
         d.d5,
         CASE WHEN fl.h10   IS NULL THEN 0 ELSE 1 END AS f100,
         CASE WHEN slr.h10  IS NULL THEN 0 ELSE 1 END AS s5,
         CASE WHEN burn.h10 IS NULL THEN 0 ELSE 1 END AS b,
         CASE WHEN whp.h9   IS NULL THEN 0 ELSE 1 END AS w
  FROM tr
  LEFT JOIN d8 d ON tr.h0 = d.h0    AND tr.h8 = d.h8
  LEFT JOIN fl   ON tr.h0 = fl.h0   AND tr.h10 = fl.h10
  LEFT JOIN slr  ON tr.h0 = slr.h0  AND tr.h10 = slr.h10
  LEFT JOIN burn ON tr.h0 = burn.h0 AND tr.h10 = burn.h10
  LEFT JOIN whp  ON tr.h0 = whp.h0  AND tr.h9 = whp.h9
)
SELECT GEOID, SUM(a * GREATEST(f100, s5, w)) / SUM(a) AS value
FROM c
GROUP BY GEOID
HAVING SUM(a) >= 0.5 * ANY_VALUE(tract_km2)                -- drop slivers of tracts mostly outside the AOI
ORDER BY GEOID

