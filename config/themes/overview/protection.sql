-- Share of the area's land by 30x30 protection status, on the res-10 grid.
-- Land = CA ecoregion grid (the 30x30 denominator); GAP shares from the
-- conserved-areas per-cell weights (sparse: no row = not in any unit).
WITH aoi10 AS MATERIALIZED ({{AOI10}}),
land AS (
  SELECT DISTINCT e.h0, e.h10
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex/h0=*/data_0.parquet') e
  JOIN aoi10 a ON e.h0 = a.h0 AND e.h10 = a.h10
),
s AS (
  SELECT SUM(h3_cell_area(l.h10, 'km^2')) AS land_km2,
         SUM(h3_cell_area(l.h10, 'km^2') * COALESCE(w.w1 + w.w2, 0)) AS gap12_km2,
         SUM(h3_cell_area(l.h10, 'km^2') * COALESCE(w.w3 + w.w4, 0)) AS gap34_km2
  FROM land l
  LEFT JOIN read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights/h0=*/data_0.parquet') w
    ON w.h0 = l.h0 AND w.h10 = l.h10
)
SELECT land_km2 * 247.105 AS land_acres,
       gap12_km2 * 247.105 AS gap12_acres,
       gap12_km2 / land_km2 AS frac_gap12,
       gap34_km2 / land_km2 AS frac_gap34,
       1 - (gap12_km2 + gap34_km2) / land_km2 AS frac_none
FROM s
