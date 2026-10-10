-- How reach grows with time: people and open-access park acres within each
-- travel-time band (cumulative: the 10-minute row includes the 5-minute area).
WITH b10 AS MATERIALIZED ({{BANDS10}}),
bands AS (SELECT DISTINCT band FROM b10),
park AS (
  SELECT DISTINCT p.h0, p.h10
  FROM read_parquet('s3://public-tpl/parkserve-2025/parks/hex/h0=*/data_0.parquet') p
  JOIN b10 a ON p.h0 = a.h0 AND p.h10 = a.h10
  WHERE p.park_access = 3
),
cell AS (
  SELECT c.band, h3_cell_area(c.h10, 'km^2') AS km2, (p.h10 IS NOT NULL) AS is_park
  FROM b10 c LEFT JOIN park p ON p.h0 = c.h0 AND p.h10 = c.h10
),
hit AS MATERIALIZED (
  SELECT x._cng_fid, a.band, any_value(x.TotPop) AS pop, COUNT(DISTINCT x.h10) AS cells_in
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet') x
  JOIN b10 a ON x.h0 = a.h0 AND x.h10 = a.h10
  GROUP BY x._cng_fid, a.band
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM b10) AND _cng_fid IN (SELECT _cng_fid FROM hit)
  GROUP BY _cng_fid
)
SELECT CAST(k.band AS VARCHAR) || ' min' AS band,
       (SELECT SUM(km2) FILTER (WHERE is_park) FROM cell WHERE cell.band <= k.band) * 247.105 AS park_acres,
       (SELECT SUM(pop * cells_in / cells_all) FROM hit JOIN tot USING (_cng_fid) WHERE hit.band <= k.band) AS population
FROM bands k
ORDER BY k.band
