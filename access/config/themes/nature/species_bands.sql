-- Species within each travel-time band (cumulative), same filters as species.sql.
WITH b10 AS MATERIALIZED ({{BANDS10}}),
occ AS (
  SELECT a.band, g.species
  FROM read_parquet('s3://public-gbif/2026-06/hex/h0=*/data_0.parquet') g
  JOIN b10 a ON g.h0 = a.h0 AND g.h10 = a.h10
  WHERE g.species IS NOT NULL
    AND NOT list_has_any(g.issue, ['ZERO_COORDINATE', 'COORDINATE_INVALID', 'COORDINATE_OUT_OF_RANGE', 'COUNTRY_COORDINATE_MISMATCH'])
    AND (g.coordinateuncertaintyinmeters IS NULL OR g.coordinateuncertaintyinmeters <= 1000)
),
first_band AS (SELECT species, MIN(band) AS band FROM occ GROUP BY species),
bands AS (SELECT DISTINCT band FROM b10)
SELECT CAST(k.band AS VARCHAR) || ' min' AS band,
       (SELECT COUNT(*) FROM first_band f WHERE f.band <= k.band) AS n_species
FROM bands k ORDER BY k.band
