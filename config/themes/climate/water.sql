-- FEMA flood hazard (100-yr = SFHA; 500-yr adds the 0.2% annual-chance zone)
-- and NOAA 5 ft sea-level-rise inundation: share of land, split by GAP 1-2.
WITH aoi AS MATERIALIZED ({{AOI}}),
land10 AS (            -- CA land reference grid (res 10) inside the AOI
  SELECT DISTINCT e.h0, e.h10
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex/h0=*/data_0.parquet') e
  JOIN aoi a ON e.h0 = a.h0 AND e.h8 = a.h8
),
prot10 AS (            -- GAP 1+2 share per res-10 cell (only conserved-touching cells have rows)
  SELECT w.h0, w.h10, w.w1 + w.w2 AS pw
  FROM read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights/h0=*/data_0.parquet') w
  JOIN aoi a ON w.h0 = a.h0 AND w.h8 = a.h8
),
fl AS (                -- FEMA NFHL flags per res-10 cell
  SELECT f.h0, f.h10,
         MAX(CASE WHEN f.SFHA_TF = 'T' THEN 1 ELSE 0 END) AS in100,
         MAX(CASE WHEN f.SFHA_TF = 'T' OR f.ZONE_SUBTY = '0.2 PCT ANNUAL CHANCE FLOOD HAZARD' THEN 1 ELSE 0 END) AS in500,
         MIN(CASE WHEN f.FLD_ZONE = 'OPEN WATER' THEN 1 ELSE 0 END) AS water
  FROM read_parquet('s3://public-hazard/flood-hazard/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  GROUP BY f.h0, f.h10
),
slr AS (               -- NOAA 5 ft sea-level-rise inundation
  SELECT DISTINCT s.h0, s.h10
  FROM read_parquet('s3://public-hazard/sea-level-rise/hex/h0=*/data_0.parquet') s
  JOIN aoi a ON s.h0 = a.h0 AND s.h8 = a.h8
  WHERE s.state = 'CA'
),
cells AS (
  SELECT h3_cell_area(l.h10, 'km^2') AS a10,
         COALESCE(fl.in100, 0) AS in100,
         COALESCE(fl.in500, 0) AS in500,
         CASE WHEN s.h10 IS NULL THEN 0 ELSE 1 END AS inslr,
         COALESCE(p.pw, 0) AS pw
  FROM land10 l
  LEFT JOIN fl     ON l.h0 = fl.h0 AND l.h10 = fl.h10
  LEFT JOIN slr s  ON l.h0 = s.h0  AND l.h10 = s.h10
  LEFT JOIN prot10 p ON l.h0 = p.h0 AND l.h10 = p.h10
  WHERE COALESCE(fl.water, 0) = 0          -- drop FEMA open-water cells (SF Bay, lakes)
)
SELECT
  SUM(a10)                                                       AS land_km2,
  SUM(a10 * in100) / SUM(a10)                                    AS fld100_share,
  SUM(a10 * in500) / SUM(a10)                                    AS fld500_share,
  SUM(a10 * inslr) / SUM(a10)                                    AS slr5ft_share,
  SUM(a10 * in100)                                               AS fld100_km2,
  SUM(a10 * in500)                                               AS fld500_km2,
  SUM(a10 * inslr)                                               AS slr5ft_km2,
  SUM(a10 * in100 * pw)       / NULLIF(SUM(a10 * pw), 0)         AS fld100_share_protected,
  SUM(a10 * in100 * (1 - pw)) / NULLIF(SUM(a10 * (1 - pw)), 0)   AS fld100_share_unprotected,
  SUM(a10 * in500 * pw)       / NULLIF(SUM(a10 * pw), 0)         AS fld500_share_protected,
  SUM(a10 * in500 * (1 - pw)) / NULLIF(SUM(a10 * (1 - pw)), 0)   AS fld500_share_unprotected,
  SUM(a10 * inslr * pw)       / NULLIF(SUM(a10 * pw), 0)         AS slr5ft_share_protected,
  SUM(a10 * inslr * (1 - pw)) / NULLIF(SUM(a10 * (1 - pw)), 0)   AS slr5ft_share_unprotected
FROM cells
