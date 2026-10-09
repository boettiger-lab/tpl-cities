-- Final USFWS critical habitat (endangered/threatened species) in the area:
-- species count, acres (whole res-8 cells), and GAP 1-2 protected share.
WITH aoi AS MATERIALIZED ({{AOI}}),
ch AS (  -- critical-habitat (feature, res-8 cell) rows inside the AOI
  SELECT c.h0, c.h8, c.sciname, c.listing_st
  FROM read_parquet('s3://public-usfws/critical-habitat/final/hex/h0=*/data_0.parquet') c
  JOIN aoi a ON c.h0 = a.h0 AND c.h8 = a.h8
  WHERE c.listing_st IN ('Endangered', 'Threatened')
),
chcell AS (SELECT DISTINCT h0, h8 FROM ch),
cells AS (  -- California land area + GAP 1+2 share for each AOI cell touched by critical habitat
  SELECT e.h0, e.h8, e.land_area_km2 AS land_km2, COALESCE(w.w1 + w.w2, 0) AS w12
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet') e
  JOIN chcell k ON e.h0 = k.h0 AND e.h8 = k.h8
  LEFT JOIN read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights-res8/h0=*/data_0.parquet') w
    ON w.h0 = e.h0 AND w.h8 = e.h8
)
SELECT (SELECT COUNT(DISTINCT sciname) FROM ch) AS n_ch_species,
       (SELECT COUNT(DISTINCT sciname) FILTER (WHERE listing_st = 'Endangered') FROM ch) AS n_ch_endangered,
       ROUND(SUM(land_km2) * 247.105) AS ch_acres,
       SUM(land_km2 * w12) / NULLIF(SUM(land_km2), 0) AS ch_frac_protected
FROM cells
