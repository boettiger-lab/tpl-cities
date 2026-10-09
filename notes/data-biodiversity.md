# Recon: BIODIVERSITY theme (SQL templates, tested)

All templates follow the contract `WITH aoi AS ({{AOI}}) ...`, joining on `(h0, h8)` against raw `read_parquet`.
Tested through the live duckdb-geo MCP server (`https://duckdb-mcp.nrp-nautilus.io/mcp`, JSON-RPC `tools/call query`); wall-clock times include HTTP round trip and vary by about 2x between runs (server load). Test AOIs:
- Alameda `06001` and Modoc `06049`: census-2024 county hex (`s3://public-census/census-2024/county/hex/h0=*/data_0.parquet`).
- Statewide: ecoregion res-8 land grid.

## !! Contract issue: the statewide AOI must use `s3://`, not `https://`
`read_parquet('https://s3-west.nrp-nautilus.io/public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet')` **fails on the MCP server**:
`Invalid Input Error: Globs (*) for generic HTTP file is are not supported`. Use
`SELECT DISTINCT h0, h8 FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet')` (that is what all statewide numbers below used).
The same applies to any other https glob path. Every template below uses `s3://` paths.

## Datasets / paths / columns

| Use | Path | Key columns |
|---|---|---|
| SGCN ranges (CDFW SWAP 2025 v4, 422 range polygons, **318 species, vertebrates only**) | `s3://public-swap/california/swap-2025/sgcn-ranges/hex/h0=*/data_0.parquet` | `ParentSpeciesKey`, `Taxonomic_Group` (Amphibians, Birds, Fish, Mammals, Reptiles), `SWAP_Scientific`, `SWAP_Common`, `h8` (always populated), `h9`/`h10` (NULL for 256 large ranges), `h0` |
| SGCN species list (1,437 rows) | `s3://public-swap/california/swap-2025/sgcn-species.parquet` | `SpeciesKey` (= ranges `ParentSpeciesKey`, 100% match), `TaxonomicGroup`, `ScientificName`, `CommonName`, `ListingStatus` (comma-joined, e.g. 'Federally Endangered, State Threatened'), `RangePresent`, `Climate` |
| Critical habitat, final (USFWS, national, 728 features / 462 spp.) | `s3://public-usfws/critical-habitat/final/hex/h0=*/data_0.parquet` (native res 8) | `sciname`, `comname`, `listing_st` (Endangered/Threatened/Extinction/'Original Data in Error'), `entity_id`, `unitname`, `h8`, `h0` |
| 30x30 GAP 1+2 per-cell share, res 8 (row for every CA land cell) | `s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights-res8/h0=*/data_0.parquet` | `h8`, `h0`, `w1`..`w4` |
| 30x30 GAP share, res 10 (sparse, inventory footprint only) | `s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights/h0=*/data_0.parquet` | `h10`, `h9`, `h8`, `h0`, `w1`..`w4` |
| CA land grid res 8 (land area weight) | `s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet` | `h8`, `h0`, `land_area_km2`, `nland` (one row per cell) |
| CA land grid res 10 | `s3://public-ca30x30/ecoregion/hex/h0=*/data_0.parquet` | `h10`, `h9`, `h8`, `h0` (one row per ecoregion x cell -> DISTINCT) |
| ACE v3 terrestrial biodiversity summary (native res 8) | `s3://public-cdfw/ace/terrestrial-biodiversity-summary/hex/h0=*/data_0.parquet` | `Hex_ID`, `BioRankSW` (0-5), `RareCount`, `NtvBird`..., `h8`, `h0` |
| Census 2024 tracts (native res 10) | `s3://public-census/census-2024/tract/hex/h0=*/data_0.parquet` | `GEOID`, `STATEFP`, `COUNTYFP`, `h10`, `h9`, `h8`, `h0` |

SGCN species-units (`sgcn-species-units`) cannot be used: its STAC description says `ParentProvSpeciesKey` does not resolve to `SpeciesKey` (pairing gives wrong species-unit assignments). Conservation units are not needed for AOI work.

**Coverage caveat (must show in the UI):** range maps exist only for SGCN **vertebrates** (318 of 1,437 SGCN: 134 birds, 73 fish, 53 mammals, 33 amphibians, 25 reptiles). The 537 plant and 359 invertebrate SGCN have no range maps (`RangePresent = 'Range Not Shown'`), so "SGCN in the AOI" means "SGCN vertebrates whose SWAP range intersects the AOI". Statewide list totals by group are available from the species table for context (Plants 537, Invertebrates 359, Birds 179, Mammals 175, Fish 99, Amphibians 45, Reptiles 43).

"Listed" = `ListingStatus` contains Federally/State Endangered/Threatened (regex `(Federally|State) (Endangered|Threatened)`); excludes candidates, proposed, State Fully Protected-only and State Rare Plant.

---

## Q1 `bio_sgcn`: SGCN richness, listed counts and range protection by taxonomic group (headline + both SGCN bar charts)
One query feeds the headline numbers (row `taxon_group = 'All'`) and the bar charts (other rows).

Metric for protection (recommended, defensible): for each species, the **area-weighted GAP 1+2 share of its in-AOI range** = sum(land_km2 x (w1+w2)) / sum(land_km2) over the species' distinct res-8 range cells inside the AOI (California land only; LEFT JOIN weights, COALESCE 0). Summaries per group: mean of those per-species shares (each species weighted equally), count of species with < 20% of in-AOI range protected (the 20% cutoff is the one the 2025 CBN Biodiversity Assessment uses for "under-represented"), and count >= 30%. `aoi_pct_land_protected` (same on every row) is the AOI's own GAP 1+2 share of land, for comparison.

```sql
WITH aoi AS ({{AOI}}),
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
       COUNT(*) FILTER (WHERE sp.prot_share < 0.20) AS n_prot_lt20pct,
       COUNT(*) FILTER (WHERE sp.prot_share >= 0.30) AS n_prot_ge30pct,
       ROUND(100 * AVG(sp.prot_share), 1) AS mean_pct_range_protected,
       ROUND(100 * ANY_VALUE(aoi_tot.aoi_prot_share), 1) AS aoi_pct_land_protected
FROM sp
JOIN read_parquet('s3://public-swap/california/swap-2025/sgcn-species.parquet') t ON t.SpeciesKey = sp.sk
CROSS JOIN aoi_tot
GROUP BY ROLLUP (t.TaxonomicGroup)
ORDER BY n_sgcn DESC
```

Output columns: `taxon_group` ('All' + 5 groups), `n_sgcn`, `n_listed`, `n_fed_listed`, `n_state_listed`, `n_prot_lt20pct`, `n_prot_ge30pct`, `mean_pct_range_protected`, `aoi_pct_land_protected`.

Results:

| AOI | group | n_sgcn | n_listed | fed | state | n_prot_lt20 | n_prot_ge30 | mean % range protected | AOI % land protected |
|---|---|---|---|---|---|---|---|---|---|
| Alameda | All | 107 | 18 | 12 | 16 | 99 | 1 | 14.9 | 15.3 |
| | Birds | 69 | 10 | 5 | 10 | 62 | 1 | 15.5 | |
| | Mammals | 18 | 2 | 2 | 2 | 18 | 0 | 13.8 | |
| | Fish | 12 | 3 | 2 | 2 | 11 | 0 | 14.3 | |
| | Amphibians | 4 | 2 | 2 | 1 | 4 | 0 | 14.9 | |
| | Reptiles | 4 | 1 | 1 | 1 | 4 | 0 | 11.8 | |
| Modoc | All | 94 | 14 | 6 | 13 | 87 | 4 | 8.9 | 5.9 |
| | Birds | 54 | 7 | 1 | 7 | 50 | 1 | 8.1 | |
| | Mammals | 20 | 2 | 2 | 2 | 19 | 1 | 10.4 | |
| | Fish | 16 | 4 | 2 | 4 | 14 | 2 | 9.6 | |
| | Amphibians | 3 | 1 | 1 | 0 | 3 | 0 | 9.0 | |
| | Reptiles | 1 | 0 | 0 | 0 | 1 | 0 | 4.4 | |
| Statewide | All | 318 | 82 | 48 | 71 | 153 | 85 | 26.3 | 26.1 |
| | Birds | 134 | 23 | 10 | 23 | 53 | 38 | 27.6 | |
| | Fish | 73 | 24 | 18 | 16 | 46 | 13 | 22.5 | |
| | Mammals | 53 | 14 | 7 | 14 | 22 | 19 | 28.9 | |
| | Amphibians | 33 | 16 | 10 | 13 | 18 | 7 | 24.4 | |
| | Reptiles | 25 | 5 | 3 | 5 | 14 | 8 | 28.1 | |

Runtime (MCP): Alameda 9.5-14.8 s, Modoc 15-19 s, statewide 8.3 s. (A listing-only variant without the protection CTEs ran 10 s Alameda / 9 s statewide; not worth a separate query.)
Statewide `aoi_pct_land_protected` = 26.1%, matching the official statewide GAP 1+2 figure, which validates the cell/weight join.

Caveats:
- SWAP ranges are coarse (many cover whole regions), so inside a single county most species' ranges cover most of the county and the per-species protected share sits close to the county's own protected share (Alameda 14.9 vs 15.3). The metric is more informative for large or heterogeneous AOIs (statewide: 153 of 318 species < 20%). Show `aoi_pct_land_protected` next to it so users can see this.
- Res-8 granularity: protected share is measured on res-8 cells (about 0.7 km2) even for the 166 small-range species with native res-10 cells.
- Count of species uses any range cell in the AOI (including water cells of the county polygon); the protection share uses California land cells only.
- Birds have multiple range features per species (seasonal); counts are by distinct species (`ParentSpeciesKey`).

## Q2 `bio_ch_summary`: USFWS final critical habitat in the AOI (headline)
```sql
WITH aoi AS ({{AOI}}),
ch AS (  -- critical-habitat (feature, res-8 cell) rows inside the AOI
  SELECT c.h0, c.h8, c.sciname, c.listing_st
  FROM read_parquet('s3://public-usfws/critical-habitat/final/hex/h0=*/data_0.parquet') c
  JOIN aoi a ON c.h0 = a.h0 AND c.h8 = a.h8
  WHERE c.listing_st IN ('Endangered', 'Threatened')
),
chcell AS (SELECT DISTINCT h0, h8 FROM ch),
cells AS (  -- California land area + GAP 1+2 share for each AOI cell touched by critical habitat
  SELECT e.h0, e.h8, e.land_area_km2 AS land_km2, COALESCE(w.w1 + w.w2, 0) AS w12
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet') e
  JOIN chcell k ON e.h0 = k.h0 AND e.h8 = k.h8
  LEFT JOIN read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights-res8/h0=*/data_0.parquet') w
    ON w.h0 = e.h0 AND w.h8 = e.h8
)
SELECT (SELECT COUNT(DISTINCT sciname) FROM ch) AS n_ch_species,
       (SELECT COUNT(DISTINCT sciname) FILTER (WHERE listing_st = 'Endangered') FROM ch) AS n_ch_endangered,
       ROUND(SUM(land_km2) * 247.105) AS ch_acres,
       ROUND(100 * SUM(land_km2 * w12) / NULLIF(SUM(land_km2), 0), 1) AS ch_pct_protected
FROM cells
```

Output (one row): `n_ch_species`, `n_ch_endangered`, `ch_acres`, `ch_pct_protected`.

| AOI | n_ch_species | n_ch_endangered | ch_acres | ch_pct_protected |
|---|---|---|---|---|
| Alameda | 7 | 1 | 201,984 | 21.9 |
| Modoc | 4 | 2 | 28,611 | 70.2 |
| Statewide | 110 | 68 | 14,597,940 | 42.3 |

Runtime: 3.4-4 s for all three.

Caveats: area is the California land area of the distinct res-8 cells that any designation touches (union, so overlapping designations are not double counted). This overstates small or thin designations (cells are counted whole), roughly correct for large ones (desert tortoise in CA 4.76 M ac; red-legged frog 1.64 M ac). 49 of 728 source features are smaller than one H3 cell and are absent from the hex. Excludes `listing_st` 'Extinction' and 'Original Data in Error'. USFWS only: NMFS (salmonid, marine) critical habitat is not in this layer. The source says the aggregated layer is generalized; legal extents are in species-specific files.

## Q3 `bio_ch_species`: top 10 critical-habitat species in the AOI by area (table)
```sql
WITH aoi AS ({{AOI}}),
ch AS (  -- distinct (species, res-8 cell) of critical habitat in the AOI
  SELECT DISTINCT c.sciname, c.comname, c.listing_st, c.h0, c.h8
  FROM read_parquet('s3://public-usfws/critical-habitat/final/hex/h0=*/data_0.parquet') c
  JOIN aoi a ON c.h0 = a.h0 AND c.h8 = a.h8
  WHERE c.listing_st IN ('Endangered', 'Threatened')
),
cells AS (
  SELECT e.h0, e.h8, e.land_area_km2 AS land_km2, COALESCE(w.w1 + w.w2, 0) AS w12
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet') e
  JOIN (SELECT DISTINCT h0, h8 FROM ch) k ON e.h0 = k.h0 AND e.h8 = k.h8
  LEFT JOIN read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights-res8/h0=*/data_0.parquet') w
    ON w.h0 = e.h0 AND w.h8 = e.h8
)
SELECT ch.comname AS common_name, ch.sciname AS scientific_name, ch.listing_st AS listing,
       ROUND(SUM(c.land_km2) * 247.105) AS ch_acres,
       ROUND(100 * SUM(c.land_km2 * c.w12) / NULLIF(SUM(c.land_km2), 0), 1) AS pct_protected
FROM ch JOIN cells c ON c.h0 = ch.h0 AND c.h8 = ch.h8
GROUP BY ALL
ORDER BY ch_acres DESC
LIMIT 10
```

Output columns: `common_name`, `scientific_name`, `listing`, `ch_acres`, `pct_protected` (up to 10 rows).

Alameda: California red-legged frog 162,594 ac (19.6%), Alameda whipsnake 78,335 (34.6%), Delta smelt 6,293 (2.4%), Vernal pool fairy shrimp 1,143 (1.7%), California tiger salamander 1,143 (15.6%), Western snowy plover 951 (91.4%), Longhorn fairy shrimp 762 (23.9%).
Modoc: Shortnose sucker 27,518 (71.3%), Lost River sucker 26,612 (73.7%), Slender Orcutt grass 730 (40.0%), Northern spotted owl 363 (49.0%).
Statewide top 3: Desert tortoise 4,756,371 (53.5%), Northern spotted owl 2,097,081 (8.4%), California red-legged frog 1,638,153 (31.1%).
Runtime: 4-5 s. Same area caveats as Q2 (Western snowy plover's 951 ac in Alameda is mostly cell rounding of a small beach unit).

## Q4 `bio_ace_rank5` (optional): ACE BioRank-5 (statewide top quintile) area in the AOI and its protected share
```sql
WITH aoi AS ({{AOI}}),
ace AS (  -- per res-8 cell: fraction of overlapping ACE hexagons in statewide BioRank 5
  SELECT x.h0, x.h8,
         AVG(CASE WHEN x.BioRankSW = 5 THEN 1.0 ELSE 0.0 END) AS f5
  FROM read_parquet('s3://public-cdfw/ace/terrestrial-biodiversity-summary/hex/h0=*/data_0.parquet') x
  JOIN aoi a ON x.h0 = a.h0 AND x.h8 = a.h8
  GROUP BY x.h0, x.h8
),
cells AS (
  SELECT e.h0, e.h8, e.land_area_km2 AS land_km2, COALESCE(w.w1 + w.w2, 0) AS w12
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet') e
  JOIN aoi a ON e.h0 = a.h0 AND e.h8 = a.h8
  LEFT JOIN read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights-res8/h0=*/data_0.parquet') w
    ON w.h0 = e.h0 AND w.h8 = e.h8
)
SELECT ROUND(SUM(c.land_km2 * COALESCE(x.f5, 0)) * 247.105) AS biorank5_acres,
       ROUND(100 * SUM(c.land_km2 * COALESCE(x.f5, 0)) / SUM(c.land_km2), 1) AS pct_aoi_biorank5,
       ROUND(100 * SUM(c.land_km2 * COALESCE(x.f5, 0) * c.w12) / NULLIF(SUM(c.land_km2 * COALESCE(x.f5, 0)), 0), 1) AS biorank5_pct_protected
FROM cells c LEFT JOIN ace x ON x.h0 = c.h0 AND x.h8 = c.h8
```

Output (one row): `biorank5_acres`, `pct_aoi_biorank5`, `biorank5_pct_protected`.

| AOI | biorank5_acres | pct_aoi_biorank5 | biorank5_pct_protected |
|---|---|---|---|
| Alameda | 287,005 | 51.9 | 20.4 |
| Modoc | 3,483 | 0.1 | 0.0 |
| Statewide | 19,914,834 | 19.6 | 21.2 |

Runtime: 3-5 s. Statewide protected share 21.2% matches the ca-30x30 system prompt's reference value for ACE BioRank-5 (21%), which validates the method. Uses the app convention that "ACE biodiversity rank" means rank 5. Res-8 cells on ACE hexagon boundaries take the fraction of overlapping ACE hexagons that are rank 5. ACE is described by CDFW as coarse-scale; not for single-hexagon interpretation.

## Q5 Tract map values (GEOID, value)
Both templates keep California tracts with **at least half their area inside the AOI** (a plain h8 join pulls in neighbours: Alameda gave 419 tracts and Modoc 8; with the majority rule they give 382 and 4. Modoc really has 4 tracts). Statewide returns 9,109 tracts (20 tracts with no ecoregion land cells drop out).

### Q5a `bio_tract_sgcn` (recommended for the biodiversity theme): number of SGCN vertebrate species whose range intersects the tract
```sql
WITH aoi AS ({{AOI}}),
tc AS (  -- all res-10 cells of CA tracts in the AOI's h0 partitions, flagged in/out of the AOI
  SELECT tr.GEOID, tr.h0, tr.h8, tr.h10, (a.h8 IS NOT NULL) AS in_aoi
  FROM read_parquet('s3://public-census/census-2024/tract/hex/h0=*/data_0.parquet') tr
  LEFT JOIN aoi a ON tr.h0 = a.h0 AND tr.h8 = a.h8
  WHERE tr.STATEFP = '06' AND tr.h0 IN (SELECT DISTINCT h0 FROM aoi)
),
keep AS (  -- tracts with at least half their area inside the AOI
  SELECT GEOID FROM tc GROUP BY GEOID
  HAVING SUM(CASE WHEN in_aoi THEN h3_cell_area(h10, 'km^2') ELSE 0 END) >= 0.5 * SUM(h3_cell_area(h10, 'km^2'))
),
t AS (SELECT DISTINCT tc.GEOID, tc.h0, tc.h8 FROM tc JOIN keep USING (GEOID)),
r AS (  -- distinct (SGCN species, res-8 cell) in the AOI
  SELECT DISTINCT r.ParentSpeciesKey AS sk, r.h0, r.h8
  FROM read_parquet('s3://public-swap/california/swap-2025/sgcn-ranges/hex/h0=*/data_0.parquet') r
  JOIN (SELECT DISTINCT h0, h8 FROM tc) a ON r.h0 = a.h0 AND r.h8 = a.h8
)
SELECT t.GEOID, COUNT(DISTINCT r.sk) AS value
FROM t LEFT JOIN r ON r.h0 = t.h0 AND r.h8 = t.h8
GROUP BY t.GEOID
```

Output: `GEOID` (string), `value` (integer species count).
Alameda: 382 tracts, range 46-86, median 65. Modoc: 4 tracts (06049000100 = 49, 000200 = 84, 000300 = 84, 000400 = 66). Statewide: 9,109 tracts, 22-112, median 59.
Runtime: Alameda 16-26 s, Modoc 20-34 s, statewide 20-22 s (slightly above target; the cost is the large SGCN-ranges h0 partition).
Caveat: coarse ranges, so neighbouring tracts often share values; small urban tracts get the richness of the res-8 cells they touch.

### Q5b `bio_tract_protected` (alternative): % of tract land in GAP 1+2, at res 10
```sql
WITH aoi AS ({{AOI}}),
tc AS (  -- all res-10 cells of CA tracts in the AOI's h0 partitions, flagged in/out of the AOI
  SELECT tr.GEOID, tr.h0, tr.h8, tr.h10, (a.h8 IS NOT NULL) AS in_aoi
  FROM read_parquet('s3://public-census/census-2024/tract/hex/h0=*/data_0.parquet') tr
  LEFT JOIN aoi a ON tr.h0 = a.h0 AND tr.h8 = a.h8
  WHERE tr.STATEFP = '06' AND tr.h0 IN (SELECT DISTINCT h0 FROM aoi)
),
keep AS (  -- tracts with at least half their area inside the AOI
  SELECT GEOID FROM tc GROUP BY GEOID
  HAVING SUM(CASE WHEN in_aoi THEN h3_cell_area(h10, 'km^2') ELSE 0 END) >= 0.5 * SUM(h3_cell_area(h10, 'km^2'))
),
t AS (SELECT DISTINCT tc.GEOID, tc.h0, tc.h8, tc.h10 FROM tc JOIN keep USING (GEOID)),
land AS (  -- California land cells at res 10 (ecoregion reference grid)
  SELECT DISTINCT e.h0, e.h10
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex/h0=*/data_0.parquet') e
  JOIN (SELECT DISTINCT h0, h8 FROM t) k ON e.h0 = k.h0 AND e.h8 = k.h8
),
w AS (  -- GAP 1+2 share of each res-10 cell (sparse: only cells touched by a conserved unit)
  SELECT w.h0, w.h10, w.w1 + w.w2 AS w12
  FROM read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights/h0=*/data_0.parquet') w
  JOIN (SELECT DISTINCT h0, h8 FROM t) k ON w.h0 = k.h0 AND w.h8 = k.h8
)
SELECT t.GEOID,
       ROUND(100 * SUM(h3_cell_area(t.h10, 'km^2') * COALESCE(w.w12, 0)) / SUM(h3_cell_area(t.h10, 'km^2')), 1) AS value
FROM t
JOIN land l ON l.h0 = t.h0 AND l.h10 = t.h10
LEFT JOIN w ON w.h0 = t.h0 AND w.h10 = t.h10
GROUP BY t.GEOID
```

Output: `GEOID`, `value` (percent, 0-100).
Alameda: 382 tracts, median 0, max 80.6, mean 2.9. Modoc: 06049000100 = 2.5, 000200 = 7.0, 000300 = 3.9, 000400 = 10.2. Statewide: 9,109 tracts, median 0, max 95.1.
Runtime: Alameda 12-13 s, Modoc 7-19 s, statewide 16-30 s.
Caveat: most urban tracts are 0, so the map is mostly empty in urban counties. It is also a land-conservation metric that the conservation theme may already cover.

Recommendation: **Q5a (SGCN richness per tract)** for the biodiversity map. Q5b if the panel needs a "protection" map instead and no other theme already shows it.

---

## Proposed biodiversity panel
Headline numbers (each with the statewide value next to it):
1. **SGCN vertebrate species in area**: `bio_sgcn` row 'All' `n_sgcn` (Alameda 107, Modoc 94; statewide 318). Subtitle: `n_listed` "of which federally or state listed as endangered or threatened" (18 / 14; statewide 82).
2. **Critical habitat**: `bio_ch_summary` `n_ch_species` species, `ch_acres` acres, `ch_pct_protected`% in GAP 1+2 (Alameda 7 spp / 202k ac / 21.9%; Modoc 4 / 28.6k / 70.2%; statewide 110 / 14.6 M / 42.3%).
3. **Average share of SGCN ranges protected**: `bio_sgcn` 'All' `mean_pct_range_protected` vs `aoi_pct_land_protected` (Alameda 14.9% vs 15.3%; Modoc 8.9% vs 5.9%; statewide 26.3% vs 26.1%). Alternative tile: ACE BioRank-5 share of area and its protected % (`bio_ace_rank5`).

Bar charts:
- A. **SGCN species by taxonomic group**, stacked or paired as listed vs not listed (`n_sgcn`, `n_listed` per group from `bio_sgcn`).
- B. **SGCN range protection by group**: either mean % of in-AOI range protected per group (with the AOI % land protected as a reference line), or a stacked count of species with < 20% / 20-30% / >= 30% of in-AOI range protected (`n_prot_lt20pct`, `n_sgcn - lt20 - ge30`, `n_prot_ge30pct`).
Optional table: top critical-habitat species (`bio_ch_species`).
Map: tracts colored by `bio_tract_sgcn`.

Statewide comparison values can be precomputed once (they do not change), using the statewide rows above.

Required footnote: SGCN counts cover only vertebrates with CDFW SWAP 2025 range maps (318 of 1,437 SGCN; no plant or invertebrate ranges). Critical habitat is USFWS final designations only.
