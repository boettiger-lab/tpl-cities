-- Share of each census tract's residents within a 10-minute walk of a park
-- (only the part of the tract inside the area counts). Block groups nest in
-- tracts, so tract = first 11 digits of the block-group GEOID. Residents are
-- apportioned as in access.sql. Labels are "<place> · <tract number>", the
-- place being the city or census-designated place at the tract's interior
-- point (else the county, when the area spans more than one).
WITH aoi10 AS MATERIALIZED ({{AOI10}}),
bgc AS MATERIALIZED (
  SELECT DISTINCT b._cng_fid, b.GEOID, b.COUNTYFP, b.TRACTCE, b.INTPTLAT, b.INTPTLON, b.h0, b.h10, b.TotPop
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet') b
  JOIN aoi10 a ON b.h0 = a.h0 AND b.h10 = a.h10
),
sv AS MATERIALIZED (
  SELECT DISTINCT s.h0, s.h10
  FROM read_parquet('s3://public-tpl/parkserve-2025/service-areas/hex/h0=*/data_0.parquet') s
  JOIN aoi10 a ON s.h0 = a.h0 AND s.h10 = a.h10
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi10) AND _cng_fid IN (SELECT DISTINCT _cng_fid FROM bgc)
  GROUP BY _cng_fid
),
per AS (
  SELECT bgc._cng_fid, any_value(bgc.GEOID) AS bg, any_value(bgc.COUNTYFP) AS cty, any_value(bgc.TRACTCE) AS tractce,
         any_value(bgc.INTPTLAT) AS lat, any_value(bgc.INTPTLON) AS lon,
         any_value(bgc.TotPop) AS pop, COUNT(*) AS cells_in, COUNT(sv.h10) AS cells_served
  FROM bgc LEFT JOIN sv ON bgc.h0 = sv.h0 AND bgc.h10 = sv.h10
  GROUP BY bgc._cng_fid
),
tr AS (
  SELECT left(bg, 11) AS GEOID, any_value(cty) AS cty, any_value(tractce) AS tractce,
         h3_latlng_to_cell(CAST(any_value(lat) AS DOUBLE), CAST(any_value(lon) AS DOUBLE), 10) AS pt,
         SUM(pop * cells_in / cells_all) AS pop,
         SUM(pop * cells_served / cells_all) AS served
  FROM per JOIN tot USING (_cng_fid)
  WHERE pop > 0
  GROUP BY left(bg, 11)
),
pt AS (SELECT GEOID, pt, h3_cell_to_parent(pt, 0) AS h0 FROM tr),
place AS (
  SELECT pt.GEOID, any_value(p.NAME) AS place
  FROM read_parquet('s3://public-census/census-2024/place/hex/h0=*/data_0.parquet') p
  JOIN pt ON p.h0 = pt.h0 AND p.h10 = pt.pt
  WHERE p.STATEFP = '06'
  GROUP BY pt.GEOID
),
names AS (
  SELECT COUNTYFP AS cty, NAME AS county
  FROM read_parquet('s3://public-census/census-2024/county.parquet') WHERE STATEFP = '06'
)
SELECT tr.GEOID,
       COALESCE(place.place || ' · ', CASE WHEN COUNT(DISTINCT tr.cty) OVER () > 1 THEN names.county || ' · ' END, 'Tract ')
         || regexp_replace(printf('%.2f', CAST(tractce AS INTEGER) / 100.0), '\.00$', '') AS tract,
       pop, pop - served AS pop_unserved, 100 * served / pop AS value
FROM tr LEFT JOIN names USING (cty) LEFT JOIN place USING (GEOID)
WHERE pop >= 1
ORDER BY pop_unserved DESC
