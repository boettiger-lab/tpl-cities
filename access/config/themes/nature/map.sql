-- Map: distinct GBIF species recorded in each res-9 hexagon (~0.1 km2).
WITH aoi10 AS MATERIALIZED ({{AOI10}})
SELECT h3_h3_to_string(g.h9) AS h9, COUNT(DISTINCT g.species) AS value
FROM read_parquet('s3://public-gbif/2026-06/hex/h0=*/data_0.parquet') g
JOIN aoi10 a ON g.h0 = a.h0 AND g.h10 = a.h10
WHERE g.species IS NOT NULL
  AND NOT list_has_any(g.issue, ['ZERO_COORDINATE', 'COORDINATE_INVALID', 'COORDINATE_OUT_OF_RANGE', 'COUNTRY_COORDINATE_MISMATCH'])
  AND (g.coordinateuncertaintyinmeters IS NULL OR g.coordinateuncertaintyinmeters <= 1000)
GROUP BY g.h9
