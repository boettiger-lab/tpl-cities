-- Wildlife Conservation Board approved-project funding. Each project's
-- funding is counted once and allocated by the share of its footprint
-- (res-8 cells) that falls inside the area.
WITH aoi AS MATERIALIZED ({{AOI}}),
hit AS MATERIALIZED (
  SELECT w._cng_fid, any_value(w.WCBFunding) AS funding, COUNT(DISTINCT w.h8) AS cells_in
  FROM read_parquet('s3://public-tpl/wcb-approved-projects/hex/h0=*/data_0.parquet') w
  JOIN aoi a ON w.h0 = a.h0 AND w.h8 = a.h8
  GROUP BY w._cng_fid
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h8) AS cells_all
  FROM read_parquet('s3://public-tpl/wcb-approved-projects/hex/h0=*/data_0.parquet')
  WHERE _cng_fid IN (SELECT _cng_fid FROM hit)
  GROUP BY _cng_fid
)
SELECT COUNT(*) AS n_projects,
       COALESCE(SUM(funding * cells_in / cells_all), 0) AS wcb_funding,
       COALESCE(SUM(funding), 0) AS wcb_funding_touching
FROM hit JOIN tot USING (_cng_fid)
