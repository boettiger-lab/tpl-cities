-- What's inside the reachable area: land area; people (ACS 2020-24 block-group
-- population apportioned by the share of each block group's res-10 cells
-- inside the area); share of land that is an open-access park (TPL ParkServe
-- 2025, park_access = 3); and mean tree canopy cover (LANDFIRE 2024, cells
-- without forest canopy count as 0%).
WITH aoi10 AS MATERIALIZED ({{AOI10}}),
land AS MATERIALIZED (
  SELECT DISTINCT e.h0, e.h10
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex/h0=*/data_0.parquet') e
  JOIN aoi10 a ON e.h0 = a.h0 AND e.h10 = a.h10
),
park AS (
  SELECT DISTINCT p.h0, p.h10
  FROM read_parquet('s3://public-tpl/parkserve-2025/parks/hex/h0=*/data_0.parquet') p
  JOIN aoi10 a ON p.h0 = a.h0 AND p.h10 = a.h10
  WHERE p.park_access = 3
),
canopy AS (
  SELECT c.h0, c.h10, AVG(c.cc) AS cc
  FROM read_parquet('s3://public-landfire/landfire-2024-cc/hex/h0=*/data_0.parquet') c
  JOIN aoi10 a ON c.h0 = a.h0 AND c.h10 = a.h10
  GROUP BY c.h0, c.h10
),
cells AS (
  SELECT SUM(h3_cell_area(l.h10, 'km^2')) AS land_km2,
         SUM(h3_cell_area(l.h10, 'km^2')) FILTER (WHERE p.h10 IS NOT NULL) AS park_km2,
         SUM(h3_cell_area(l.h10, 'km^2') * COALESCE(c.cc, 0)) / SUM(h3_cell_area(l.h10, 'km^2')) / 100 AS canopy
  FROM land l
  LEFT JOIN park p ON p.h0 = l.h0 AND p.h10 = l.h10
  LEFT JOIN canopy c ON c.h0 = l.h0 AND c.h10 = l.h10
),
hit AS MATERIALIZED (
  SELECT b._cng_fid, any_value(b.TotPop) AS pop, COUNT(DISTINCT b.h10) AS cells_in
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet') b
  JOIN aoi10 a ON b.h0 = a.h0 AND b.h10 = a.h10
  GROUP BY b._cng_fid
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi10) AND _cng_fid IN (SELECT _cng_fid FROM hit)
  GROUP BY _cng_fid
),
people AS (SELECT SUM(pop * cells_in / cells_all) AS population FROM hit JOIN tot USING (_cng_fid))
SELECT c.land_km2,
       p.population,
       COALESCE(c.park_km2, 0) / NULLIF(c.land_km2, 0) AS frac_park,
       COALESCE(c.park_km2, 0) * 247.105 AS park_acres,
       1000 * COALESCE(c.park_km2, 0) * 247.105 / NULLIF(p.population, 0) AS park_acres_per_1000,
       c.canopy
FROM cells c, people p
