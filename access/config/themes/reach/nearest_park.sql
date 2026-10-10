-- Nearest open-access park (TPL ParkServe 2025) to the starting point, searched
-- within ~1.7 km (25 rings of res-10 cells); straight-line distance to the
-- nearest park cell centre.
WITH pt AS (SELECT h3_latlng_to_cell({{ORIGIN_LAT}}, {{ORIGIN_LON}}, 10) AS c),
disk AS (
  SELECT h3_cell_to_parent(h10, 0) AS h0, h10
  FROM (SELECT unnest(h3_grid_disk((SELECT c FROM pt), 25)) AS h10)
),
hits AS (
  SELECT p.park_name,
         ST_Distance_Sphere(ST_Point({{ORIGIN_LAT}}, {{ORIGIN_LON}}),
                            ST_Point(h3_cell_to_lat(p.h10), h3_cell_to_lng(p.h10))) AS dist_m
  FROM read_parquet('s3://public-tpl/parkserve-2025/parks/hex/h0=*/data_0.parquet') p
  JOIN disk d ON p.h0 = d.h0 AND p.h10 = d.h10
  WHERE p.park_access = 3
)
SELECT park_name, MIN(dist_m) AS dist_m FROM hits GROUP BY park_name ORDER BY dist_m LIMIT 1
