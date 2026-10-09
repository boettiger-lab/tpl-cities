-- CAL FIRE wildfire perimeters and prescribed burns, 2021-2025 (res-10 cells;
-- each burned cell counted once), split by GAP 1-2 protection.
WITH aoi AS MATERIALIZED ({{AOI}}),
burn AS (                      -- one row per (res-10 cell, year) burned by wildfire 2021-2025
  SELECT DISTINCT f.h0, f.h10, f.YEAR_
  FROM read_parquet('s3://public-fire/calfire-2025/firep/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  WHERE f.YEAR_ BETWEEN 2021 AND 2025
),
rx AS (                        -- res-10 cells with a prescribed burn 2021-2025
  SELECT DISTINCT r.h0, r.h10
  FROM read_parquet('s3://public-fire/calfire-2025/rxburn/hex/h0=*/data_0.parquet') r
  JOIN aoi a ON r.h0 = a.h0 AND r.h8 = a.h8
  WHERE r.YEAR_ BETWEEN 2021 AND 2025
),
prot10 AS (
  SELECT w.h0, w.h10, w.w1 + w.w2 AS pw
  FROM read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights/h0=*/data_0.parquet') w
  JOIN aoi a ON w.h0 = a.h0 AND w.h8 = a.h8
),
cell AS (                      -- union of wildfire / rx cells, one row per cell
  SELECT h0, h10, SUM(n_years) AS n_years, MAX(is_rx) AS is_rx
  FROM (
    SELECT h0, h10, COUNT(*) AS n_years, 0 AS is_rx FROM burn GROUP BY h0, h10
    UNION ALL
    SELECT h0, h10, 0, 1 FROM rx
  ) GROUP BY h0, h10
),
cw AS (
  SELECT c.n_years, c.is_rx,
         h3_cell_area(c.h10, 'km^2') * 247.105 AS ac,
         COALESCE(w.pw, 0) AS pw
  FROM cell c
  LEFT JOIN prot10 w ON c.h0 = w.h0 AND c.h10 = w.h10
),
land8 AS (
  SELECT e.h0, e.h8, e.land_area_km2
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet') e
  JOIN aoi a ON e.h0 = a.h0 AND e.h8 = a.h8
),
prot8 AS (
  SELECT w.h0, w.h8, w.w1 + w.w2 AS pw
  FROM read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights-res8/h0=*/data_0.parquet') w
  JOIN aoi a ON w.h0 = a.h0 AND w.h8 = a.h8
),
land AS (
  SELECT SUM(l.land_area_km2) * 247.105 AS land_ac,
         SUM(l.land_area_km2 * COALESCE(p.pw, 0)) * 247.105 AS prot_ac
  FROM land8 l LEFT JOIN prot8 p ON l.h0 = p.h0 AND l.h8 = p.h8
),
s AS (
  SELECT
    COALESCE(SUM(ac)               FILTER (WHERE n_years > 0), 0) AS burned_ac_unique,
    COALESCE(SUM(ac * n_years), 0)                                AS burned_ac_incl_reburn,
    COALESCE(SUM(ac * pw)          FILTER (WHERE n_years > 0), 0) AS burned_ac_protected,
    COALESCE(SUM(ac * (1 - pw))    FILTER (WHERE n_years > 0), 0) AS burned_ac_unprotected,
    COALESCE(SUM(ac)               FILTER (WHERE is_rx = 1), 0)   AS rx_ac_unique,
    COALESCE(SUM(ac * pw)          FILTER (WHERE is_rx = 1), 0)   AS rx_ac_protected
  FROM cw
)
SELECT s.*,
       s.burned_ac_unique / land.land_ac                                    AS burned_share,
       s.burned_ac_protected / NULLIF(land.prot_ac, 0)                      AS burned_share_protected,
       s.burned_ac_unprotected / NULLIF(land.land_ac - land.prot_ac, 0)     AS burned_share_unprotected,
       s.rx_ac_unique / land.land_ac                                        AS rx_share,
       land.land_ac, land.prot_ac
FROM s, land
