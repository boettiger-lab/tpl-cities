-- GBIF occurrences (2026-06 snapshot) inside the reachable area: distinct
-- species and records by group, plus an 'All' row. Quality filter: drop
-- records flagged with coordinate errors and keep coordinate uncertainty
-- <= 1 km (or unreported).
WITH aoi10 AS MATERIALIZED ({{AOI10}}),
occ AS (
  SELECT g.species, g.kingdom, g.class, g.datasetkey
  FROM read_parquet('s3://public-gbif/2026-06/hex/h0=*/data_0.parquet') g
  JOIN aoi10 a ON g.h0 = a.h0 AND g.h10 = a.h10
  WHERE g.species IS NOT NULL
    AND NOT list_has_any(g.issue, ['ZERO_COORDINATE', 'COORDINATE_INVALID', 'COORDINATE_OUT_OF_RANGE', 'COUNTRY_COORDINATE_MISMATCH'])
    AND (g.coordinateuncertaintyinmeters IS NULL OR g.coordinateuncertaintyinmeters <= 1000)
),
grouped AS (
  SELECT species,
         CASE WHEN class = 'Aves' THEN 'Birds'
              WHEN kingdom = 'Plantae' THEN 'Plants'
              WHEN class = 'Insecta' THEN 'Insects'
              WHEN class = 'Mammalia' THEN 'Mammals'
              WHEN class IN ('Reptilia', 'Squamata', 'Testudines', 'Crocodylia', 'Amphibia') THEN 'Reptiles & amphibians'
              WHEN kingdom = 'Fungi' THEN 'Fungi & lichens'
              ELSE 'Other' END AS grp
  FROM occ
)
SELECT COALESCE(grp, 'All') AS grp,
       COUNT(DISTINCT species) AS n_species,
       COUNT(*) AS n_records
FROM grouped
GROUP BY ROLLUP (grp)
ORDER BY grp = 'All' DESC, n_species DESC
