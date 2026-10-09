-- SGCN (CA State Wildlife Action Plan 2025 Species of Greatest Conservation Need)
-- whose mapped range overlaps the area, by taxonomic group (plus an 'All' row).
-- Range maps exist only for vertebrate SGCN. For each species, the protected
-- share is the land-area-weighted GAP 1-2 share of its range cells inside the area.
WITH aoi AS MATERIALIZED ({{AOI}}),
cells AS (  -- AOI California-land cells: land area + GAP 1+2 (30x30) share of each res-8 cell
  SELECT e.h0, e.h8, e.land_area_km2 AS land_km2, COALESCE(w.w1 + w.w2, 0) AS w12
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet') e
  JOIN aoi a ON e.h0 = a.h0 AND e.h8 = a.h8
  LEFT JOIN read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights-res8/h0=*/data_0.parquet') w
    ON w.h0 = e.h0 AND w.h8 = e.h8
),
spcell AS (  -- distinct (species, res-8 cell) pairs inside the AOI
  SELECT DISTINCT r.ParentSpeciesKey AS sk, r.h0, r.h8
  FROM read_parquet('s3://public-swap/california/swap-2025/sgcn-ranges/hex/h0=*/data_0.parquet') r
  JOIN aoi a ON r.h0 = a.h0 AND r.h8 = a.h8
),
sp AS (  -- per species: in-AOI range land area and its area-weighted GAP 1+2 share
  SELECT s.sk, SUM(c.land_km2) AS range_km2,
         SUM(c.land_km2 * c.w12) / NULLIF(SUM(c.land_km2), 0) AS prot_share
  FROM spcell s JOIN cells c ON c.h0 = s.h0 AND c.h8 = s.h8
  GROUP BY s.sk
),
aoi_tot AS (SELECT SUM(land_km2 * w12) / SUM(land_km2) AS aoi_prot_share FROM cells)
SELECT COALESCE(t.TaxonomicGroup, 'All') AS taxon_group,
       COUNT(*) AS n_sgcn,
       COUNT(*) FILTER (WHERE regexp_matches(t.ListingStatus, '(Federally|State) (Endangered|Threatened)')) AS n_listed,
       COUNT(*) FILTER (WHERE regexp_matches(t.ListingStatus, 'Federally (Endangered|Threatened)')) AS n_fed_listed,
       COUNT(*) FILTER (WHERE regexp_matches(t.ListingStatus, 'State (Endangered|Threatened)')) AS n_state_listed,
       COUNT(*) - n_listed AS n_not_listed,
       COUNT(*) FILTER (WHERE sp.prot_share < 0.20) AS n_prot_lt20pct,
       COUNT(*) FILTER (WHERE sp.prot_share >= 0.20 AND sp.prot_share < 0.30) AS n_prot_20_30pct,
       COUNT(*) FILTER (WHERE sp.prot_share >= 0.30) AS n_prot_ge30pct,
       AVG(sp.prot_share) AS mean_range_protected,
       ANY_VALUE(aoi_tot.aoi_prot_share) AS aoi_land_protected
FROM sp
JOIN read_parquet('s3://public-swap/california/swap-2025/sgcn-species.parquet') t ON t.SpeciesKey = sp.sk
CROSS JOIN aoi_tot
GROUP BY ROLLUP (t.TaxonomicGroup)
ORDER BY n_sgcn DESC
