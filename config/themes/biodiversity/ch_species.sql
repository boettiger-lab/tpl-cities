-- Top 10 species by critical-habitat acres in the area, split by protection.
WITH aoi AS MATERIALIZED ({{AOI}}),
ch AS (  -- distinct (species, res-8 cell) of critical habitat in the AOI
  SELECT DISTINCT c.sciname, c.comname, c.listing_st, c.h0, c.h8
  FROM read_parquet('s3://public-usfws/critical-habitat/final/hex/h0=*/data_0.parquet') c
  JOIN aoi a ON c.h0 = a.h0 AND c.h8 = a.h8
  WHERE c.listing_st IN ('Endangered', 'Threatened')
),
cells AS (
  SELECT e.h0, e.h8, e.land_area_km2 AS land_km2, COALESCE(w.w1 + w.w2, 0) AS w12
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet') e
  JOIN (SELECT DISTINCT h0, h8 FROM ch) k ON e.h0 = k.h0 AND e.h8 = k.h8
  LEFT JOIN read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights-res8/h0=*/data_0.parquet') w
    ON w.h0 = e.h0 AND w.h8 = e.h8
)
SELECT ch.comname AS common_name, ch.sciname AS scientific_name, ch.listing_st AS listing,
       SUM(c.land_km2) * 247.105 AS ch_acres,
       SUM(c.land_km2 * c.w12) * 247.105 AS ch_acres_protected,
       SUM(c.land_km2 * (1 - c.w12)) * 247.105 AS ch_acres_unprotected,
       SUM(c.land_km2 * c.w12) / NULLIF(SUM(c.land_km2), 0) AS frac_protected
FROM ch JOIN cells c ON c.h0 = ch.h0 AND c.h8 = ch.h8
GROUP BY ALL
ORDER BY ch_acres DESC
LIMIT 10
