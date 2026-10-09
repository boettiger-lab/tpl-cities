-- Wildfire vs prescribed-burn acres by year, 2021-2025.
WITH aoi AS MATERIALIZED ({{AOI}}),
wf AS (
  SELECT DISTINCT f.h10, f.YEAR_ AS yr
  FROM read_parquet('s3://public-fire/calfire-2025/firep/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  WHERE f.YEAR_ BETWEEN 2021 AND 2025
),
rx AS (
  SELECT DISTINCT r.h10, r.YEAR_ AS yr
  FROM read_parquet('s3://public-fire/calfire-2025/rxburn/hex/h0=*/data_0.parquet') r
  JOIN aoi a ON r.h0 = a.h0 AND r.h8 = a.h8
  WHERE r.YEAR_ BETWEEN 2021 AND 2025
),
yrs AS (SELECT UNNEST(range(2021, 2026)) AS yr)
SELECT CAST(y.yr AS VARCHAR) AS year,
       COALESCE((SELECT SUM(h3_cell_area(h10, 'km^2')) FROM wf WHERE wf.yr = y.yr), 0) * 247.105 AS wildfire_ac,
       COALESCE((SELECT SUM(h3_cell_area(h10, 'km^2')) FROM rx WHERE rx.yr = y.yr), 0) * 247.105 AS rx_burn_ac
FROM yrs y
ORDER BY y.yr
