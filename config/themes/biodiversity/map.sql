-- Map: number of SGCN species whose range overlaps each census tract.
-- Tracts count toward the area by majority of their res-10 cells.
WITH aoi10 AS MATERIALIZED ({{AOI10}}),
hit AS MATERIALIZED (
  SELECT t.GEOID, COUNT(DISTINCT t.h10) AS cells_in
  FROM read_parquet('s3://public-census/census-2024/tract/hex/h0=*/data_0.parquet') t
  JOIN aoi10 a ON t.h0 = a.h0 AND t.h10 = a.h10
  WHERE t.STATEFP = '06'
  GROUP BY t.GEOID
),
tc AS MATERIALIZED (
  SELECT GEOID, h0, h8, h10
  FROM read_parquet('s3://public-census/census-2024/tract/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi10) AND GEOID IN (SELECT GEOID FROM hit)
),
keep AS (
  SELECT GEOID FROM tc JOIN hit USING (GEOID)
  GROUP BY GEOID HAVING any_value(cells_in) >= 0.5 * COUNT(DISTINCT h10)
),
t AS MATERIALIZED (SELECT DISTINCT tc.GEOID, tc.h0, tc.h8 FROM tc SEMI JOIN keep USING (GEOID)),
r AS (
  SELECT DISTINCT r.ParentSpeciesKey AS sk, r.h0, r.h8
  FROM read_parquet('s3://public-swap/california/swap-2025/sgcn-ranges/hex/h0=*/data_0.parquet') r
  JOIN (SELECT DISTINCT h0, h8 FROM t) a ON r.h0 = a.h0 AND r.h8 = a.h8
)
SELECT t.GEOID, COUNT(DISTINCT r.sk) AS value
FROM t LEFT JOIN r ON r.h0 = t.h0 AND r.h8 = t.h8
GROUP BY t.GEOID
