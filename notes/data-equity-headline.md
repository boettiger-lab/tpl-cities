# Recon: AOI boundaries, headline numbers, health & equity, tract map layer

Everything below was run against the `duckdb-geo` MCP `query` tool in October 2026. Timings are rough wall-clock times for the MCP round trip, measured by bracketing calls with `date`, and may include caching.
Test AOIs: Alameda `06001`, Modoc `06049`, and statewide (all CA land cells).

## 0. General findings (read first)

* **Output format: rows are TRUNCATED at 50.** The tool returns a markdown table and shows only the first 50 rows, followed by
  `⚠️ Showing the first 50 rows only ...`. Long *strings* are **not** truncated: I tested a 50,000-char cell and got it back intact.
  The markdown renderer pads the header and `|:---|` separator to the cell width, so the payload is roughly 3x the string length.
  **Workaround (tested):** any query that can return more than 50 rows returns ONE row with a JSON string column:
  * object map: `CAST(to_json(map_from_entries(list((GEOID, value) ORDER BY GEOID))) AS VARCHAR)` gives `{"06037101110":38.5,...}`
  * array of records: `CAST(to_json(list({'id': GEOID, 'name': NAME, 'lat': ..., 'lon': ...} ORDER BY NAME)) AS VARCHAR)`
  * array: `CAST(to_json(list(GEOID ORDER BY GEOID)) AS VARCHAR)`
  LA County CES map: 2,505 tracts, 47.5 KB of JSON, about 5 s. The app parses the third line of the markdown table (`| <json> |`), then strips the leading `| ` and trailing ` |`.
* **Leading zeros are preserved** on all string GEOIDs (`06001`, `0601`, `06001400100`) in the markdown output. CES5 `tract` is a FLOAT (`6001400100.0`), so the queries rebuild it with
  `lpad(CAST(CAST(tract AS BIGINT) AS VARCHAR), 11, '0')`.
* **STATEFP is VARCHAR (`'06'`) in every census hex and flat file checked** (county, place, cd, sldl, sldu, tract, acs blockgroup). I found no type mismatch.
  Other type quirks:
  * `h0` is BIGINT in the census and ecoregion files but UBIGINT in `hex-weights-res8`. Joins on `h0` still work, with an implicit cast and no slowdown seen.
  * The ecoregion **https** path from the prompt fails: `Globs (*) for generic HTTP file is are not supported`. Use the **s3://** path: `s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet`.
* **Use `WITH aoi AS MATERIALIZED ({{AOI}})`.** One DAC query took about 48 s with a plain CTE and about 7 s with `MATERIALIZED`, because DuckDB otherwise inlined the CTE more than once. Every template below uses `MATERIALIZED` on `aoi`, and on any CTE that is referenced twice.
* **Feature-in-AOI rule (recommendation: majority).** For tract, block-group and project features (native h10):
  1. count the feature's distinct h10 cells that fall in the AOI's h8 cells (`cells_in`);
  2. count all of its h10 cells (`cells_all`), reading only the AOI's `h0` partitions (`WHERE h0 IN (SELECT DISTINCT h0 FROM aoi) AND _cng_fid IN (...)`). This is cheap.
  3. A feature is in the AOI if `cells_in >= 0.5 * cells_all`.

  Results of this rule:
  * Alameda tracts: 382 selected, 379 true, 3 false positives, 0 false negatives.
  * Alameda population: majority 1,668,548 vs. true 1,649,473 (+1.2%).
  * Modoc population: majority 8,600, which is exact.
  * Statewide population: 39,288,764 vs. 39,287,377.
* **Caveat: the h8 AOI overhang matters for small AOIs (cities).** h8 AOI cells are any-touch, so they extend about 0.5 km past the boundary.
  * Oakland (`0653000`): h8 AOI gives population 494,955. Joining on the place's own h10 cells gives 439,418, which matches ACS (about 436k).
  * The extra people come from the Piedmont enclave, Berkeley, Emeryville and San Leandro edges.
  * For counties the error is about 1%.
  * **Suggested optional contract extension:** a `{{AOI10}}` token returning `(h0, h8, h10)` (query `P1-h10` below), used by population-type queries. Sources:
    * place/cd/sldl/sldu: their own hex (native h10)
    * county: `census-2024-tract` hex filtered `STATEFP='06' AND COUNTYFP='001'` (the county hex itself is h8 only)
    * statewide: `s3://public-ca30x30/ecoregion/hex/h0=*/data_0.parquet` (h10)

## 1. Jurisdiction AOI sources

All hex files carry `h0` and `h8`. Only the county hex is native h8; the others are native h10 with an h8 parent column, so `SELECT DISTINCT h0, h8` is the right AOI.

| Level | Hex path (AOI) | CA filter | id col | display name | h8 cells (example) | PMTiles (https) | source-layer | id property |
|---|---|---|---|---|---|---|---|---|
| County | `s3://public-census/census-2024/county/hex/h0=*/data_0.parquet` (native h8) | `STATEFP='06'` | `GEOID` (5) | `NAME` (or `NAMELSAD` "Alameda County") | Alameda 2,905; Modoc 14,994 | `https://s3-west.nrp-nautilus.io/public-census/census-2024/county.pmtiles` | `county` | `GEOID` |
| Incorporated city | `s3://public-census/census-2024/place/hex/h0=*/data_0.parquet` (native h10, has h8) | `STATEFP='06' AND CLASSFP LIKE 'C%'` (482 places: 461 C1/LSAD 25 city + 21 C1/LSAD 43 town; CDPs are U1/U2, military M2) | `GEOID` (7, e.g. `0653000`) | `NAMELSAD` ("Oakland city") or `NAME` | Oakland 328 | `https://s3-west.nrp-nautilus.io/public-census/census-2024/place.pmtiles` | `place` | `GEOID` |
| Congressional district (119th) | `s3://public-census/census-2024/cd/hex/h0=*/data_0.parquet` (h10) | `STATEFP='06'` (52) | `GEOID` (4, `0612`) | `NAMELSAD` ("Congressional District 12") | CD12 529 | `https://s3-west.nrp-nautilus.io/public-census/census-2024/cd.pmtiles` | `cd` | `GEOID` |
| State Assembly | `s3://public-census/census-2025/sldl/hex/h0=*/data_0.parquet` (h10) | `STATEFP='06'` (80) | `GEOID` (5, `06001`) | `NAMELSAD` ("Assembly District 1") | AD1 95,987 | `https://s3-west.nrp-nautilus.io/public-census/census-2025/sldl.pmtiles` | `sldl` | `GEOID` |
| State Senate | `s3://public-census/census-2025/sldu/hex/h0=*/data_0.parquet` (h10) | `STATEFP='06'` (40) | `GEOID` (5, `06001`) | `NAMELSAD` ("State Senate District 1") | SD1 113,786 | `https://s3-west.nrp-nautilus.io/public-census/census-2025/sldu.pmtiles` | `sldu` | `GEOID` |
| Census tract | `s3://public-census/census-2024/tract/hex/h0=*/data_0.parquet` (h10) | `STATEFP='06'` (9,129) | `GEOID` (11) | `NAMELSAD` | | `https://s3-west.nrp-nautilus.io/public-census/census-2024/tract.pmtiles` (790 MB) | `tract` | `GEOID` |

**Warning: GEOIDs collide across levels.** Assembly `06001`, Senate `06001` and Alameda County `06001` are all the same string, so the app must key on (level, GEOID).

All PMTiles URLs return HTTP 200. The catalog's s3:// hrefs map to `https://s3-west.nrp-nautilus.io/<bucket>/<key>`. PMTiles properties include `STATEFP`, `GEOID`, `NAMELSAD`, and `NAME` where it exists.
To highlight a boundary, filter with `['==', ['get','GEOID'], id]`. For cities, also filter `CLASSFP` on `C*` if drawing all places.

AOI expansions (tested; all six together took about 14 s, so each is a few seconds):
```sql
-- county
SELECT DISTINCT h0, h8 FROM read_parquet('s3://public-census/census-2024/county/hex/h0=*/data_0.parquet') WHERE STATEFP='06' AND GEOID='06001'
-- city
SELECT DISTINCT h0, h8 FROM read_parquet('s3://public-census/census-2024/place/hex/h0=*/data_0.parquet') WHERE STATEFP='06' AND GEOID='0653000'
-- congressional
SELECT DISTINCT h0, h8 FROM read_parquet('s3://public-census/census-2024/cd/hex/h0=*/data_0.parquet') WHERE STATEFP='06' AND GEOID='0612'
-- assembly
SELECT DISTINCT h0, h8 FROM read_parquet('s3://public-census/census-2025/sldl/hex/h0=*/data_0.parquet') WHERE STATEFP='06' AND GEOID='06001'
-- senate
SELECT DISTINCT h0, h8 FROM read_parquet('s3://public-census/census-2025/sldu/hex/h0=*/data_0.parquet') WHERE STATEFP='06' AND GEOID='06001'
-- statewide (525,034 cells, 410,641 km2)
SELECT DISTINCT h0, h8 FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet')
```

### L1–L5 pick-list queries (one JSON string row; tested, each <5 s)
These never change, so I recommend generating them once and shipping them as static JSON.
```sql
-- L1 county (58)
SELECT CAST(to_json(list({'id': GEOID, 'name': NAME, 'lat': CAST(INTPTLAT AS DOUBLE), 'lon': CAST(INTPTLON AS DOUBLE)} ORDER BY NAME)) AS VARCHAR) AS j
FROM read_parquet('s3://public-census/census-2024/county.parquet') WHERE STATEFP = '06'
-- L2 incorporated city (482; ~37 KB)
SELECT CAST(to_json(list({'id': GEOID, 'name': NAMELSAD, 'lat': CAST(INTPTLAT AS DOUBLE), 'lon': CAST(INTPTLON AS DOUBLE)} ORDER BY NAME)) AS VARCHAR) AS j
FROM read_parquet('s3://public-census/census-2024/place.parquet') WHERE STATEFP = '06' AND CLASSFP LIKE 'C%'
-- L3 congressional (52)
SELECT CAST(to_json(list({'id': GEOID, 'name': NAMELSAD, 'lat': CAST(INTPTLAT AS DOUBLE), 'lon': CAST(INTPTLON AS DOUBLE)} ORDER BY GEOID)) AS VARCHAR) AS j
FROM read_parquet('s3://public-census/census-2024/cd.parquet') WHERE STATEFP = '06'
-- L4 assembly (80)
SELECT CAST(to_json(list({'id': GEOID, 'name': NAMELSAD, 'lat': CAST(INTPTLAT AS DOUBLE), 'lon': CAST(INTPTLON AS DOUBLE)} ORDER BY GEOID)) AS VARCHAR) AS j
FROM read_parquet('s3://public-census/census-2025/sldl.parquet') WHERE STATEFP = '06'
-- L5 senate (40)
SELECT CAST(to_json(list({'id': GEOID, 'name': NAMELSAD, 'lat': CAST(INTPTLAT AS DOUBLE), 'lon': CAST(INTPTLON AS DOUBLE)} ORDER BY GEOID)) AS VARCHAR) AS j
FROM read_parquet('s3://public-census/census-2025/sldu.parquet') WHERE STATEFP = '06'
```
Sample output: `[{"id":"06001","name":"Alameda","lat":37.6471385,"lon":-121.912488},...]`.
The county, cd, sldl, sldu and tract flat files also have a `bbox` struct (xmin, ymin, xmax, ymax) if you want fit-to-bounds; place does not.

## 2. T1: census tracts in AOI (majority rule)

```sql
WITH aoi AS MATERIALIZED ({{AOI}}),
hit AS MATERIALIZED (
  SELECT t.GEOID, COUNT(DISTINCT t.h10) AS cells_in
  FROM read_parquet('s3://public-census/census-2024/tract/hex/h0=*/data_0.parquet') t
  JOIN aoi a ON t.h0 = a.h0 AND t.h8 = a.h8
  WHERE t.STATEFP = '06'
  GROUP BY t.GEOID
),
tot AS (
  SELECT GEOID, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-census/census-2024/tract/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi) AND GEOID IN (SELECT GEOID FROM hit)
  GROUP BY GEOID
)
SELECT COUNT(*) AS n_tracts,
       CAST(to_json(list(GEOID ORDER BY GEOID)) AS VARCHAR) AS geoids
FROM hit JOIN tot USING (GEOID)
WHERE cells_in >= 0.5 * cells_all
```
* Output: `n_tracts`, `geoids` (JSON array).
* Alameda: 382 tracts (419 touch the AOI; 379 are true Alameda tracts, with 3 small cross-boundary false positives), about 6 s.
* Modoc: 4 tracts, `["06049000100","06049000200","06049000300","06049000400"]`.
* Recommendation: use majority. Any-overlap pulls in 37 extra neighbouring tracts for Alameda.

## 3. Headline numbers

### H1: WCB funding in AOI
```sql
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
       SUM(funding) AS wcb_funding_any_overlap,
       SUM(funding * cells_in / cells_all) AS wcb_funding_apportioned,
       COUNT(*) FILTER (WHERE cells_in < cells_all) AS n_projects_spanning_boundary
FROM hit JOIN tot USING (_cng_fid)
```
Output: `n_projects`, `wcb_funding_any_overlap`, `wcb_funding_apportioned`, `n_projects_spanning_boundary`.

| AOI | n_projects | any_overlap $ | apportioned $ | spanning | time |
|---|---|---|---|---|---|
| Alameda | 33 | 122,158,814 | 91,565,145 | 5 | ~4 s |
| Modoc | 30 | 19,807,870 | 12,631,740 | 8 | ~4 s |
| Statewide | 3,581 | 4,412,854,200 | 4,411,615,225 | 9 | ~10 s |

* Dedup is by `_cng_fid`, which is row-unique. Two `ProjectID`s are duplicated in the source, so do not dedup on `ProjectID`.
* `tot` scans the whole WCB hex, but it is small (1.3M rows) and fast.
* **Recommendation:** headline the apportioned figure, labelled "allocated by project footprint share", and show the any-overlap figure as "projects touching the AOI".
  * Example: the $74M "San Francisco Baylands (Cargill Salt Ponds)" project (County=Napa) touches Alameda with 129 of 215 h8 cells.
* Caveats:
  * About 334 of 3,915 projects (tiny placeholder polygons) are absent from the hex. The flat-file statewide total is $4.50B vs. $4.41B in the hex.
  * About half the polygons carry CDFW's "not actual project area" disclaimer.
  * `dtmBoardAp` is the approval date.

### H2: share of AOI land protected (GAP 1+2) and GAP 3+4
```sql
WITH aoi AS MATERIALIZED ({{AOI}}),
land AS (
  SELECT e.h0, e.h8, e.land_area_km2
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet') e
  JOIN aoi a ON e.h0 = a.h0 AND e.h8 = a.h8
)
SELECT SUM(l.land_area_km2) AS land_km2,
       SUM(l.land_area_km2 * COALESCE(w.w1 + w.w2, 0)) AS gap12_km2,
       SUM(l.land_area_km2 * COALESCE(w.w3 + w.w4, 0)) AS gap34_km2,
       gap12_km2 / land_km2 AS frac_gap12,
       gap34_km2 / land_km2 AS frac_gap34
FROM land l
LEFT JOIN read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights-res8/h0=*/data_0.parquet') w
  ON w.h0 = l.h0 AND w.h8 = l.h8
```

| AOI | land km² | GAP1+2 km² | GAP3+4 km² | frac GAP1+2 | frac GAP3+4 | time |
|---|---|---|---|---|---|---|
| Alameda | 2,238.5 | 343.5 | 226.9 | 15.3% | 10.1% | ~4 s |
| Modoc | 10,968.7 | 645.0 | 6,562.8 | 5.9% | 59.8% | ~5 s |
| Statewide | 410,641 | 107,320 | 105,262 | 26.1% | 25.6% | ~8 s |
| Senate District 1 (113k cells) | 84,336 | 9,541 | 35,480 | 11.3% | 42.1% | ~5 s |

* Statewide matches the STAC numbers (26.47M acres GAP 1+2 out of 101.5M acres total = 26.1%).
* For acres, multiply km² by 247.105.
* The Alameda land figure is above Census ALAND (1,914 km²) because of h8 boundary overhang into neighbouring counties and the shoreline.

### H3: population and median household income (ACS 2020–2024 block groups)
Source choice: `acs-2020-2024-blockgroup`. It is the newest vintage and the finest unit, and it carries both `TotPop` and `MHHI`. I did not inspect SVI or CES further because they are coarser and older.
```sql
WITH aoi AS MATERIALIZED ({{AOI}}),
hit AS MATERIALIZED (
  SELECT b._cng_fid, b.h0, any_value(b.TotPop) AS pop, any_value(b.MHHI) AS mhhi,
         COUNT(DISTINCT b.h10) AS cells_in
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet') b
  JOIN aoi a ON b.h0 = a.h0 AND b.h8 = a.h8
  GROUP BY b._cng_fid, b.h0
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi) AND _cng_fid IN (SELECT _cng_fid FROM hit)
  GROUP BY _cng_fid
),
bg AS (
  SELECT h._cng_fid, any_value(pop) AS pop, any_value(mhhi) AS mhhi, SUM(cells_in) / any_value(t.cells_all) AS frac
  FROM hit h JOIN tot t USING (_cng_fid) GROUP BY h._cng_fid
)
SELECT COUNT(*) FILTER (WHERE frac >= 0.5) AS n_bg,
       SUM(pop) FILTER (WHERE frac >= 0.5) AS pop_majority,
       SUM(pop * frac) AS pop_apportioned,
       SUM(mhhi * pop) FILTER (WHERE frac >= 0.5 AND mhhi IS NOT NULL)
         / SUM(pop) FILTER (WHERE frac >= 0.5 AND mhhi IS NOT NULL) AS mhhi_popweighted_bg_mean
FROM bg
```

| AOI | pop_majority | pop_apportioned | (any overlap) | truth (flat, county filter) | MHHI pop-wtd BG mean | time |
|---|---|---|---|---|---|---|
| Alameda | 1,668,548 | 1,676,401 | 1,751,641 | 1,649,473 | $146,171 (flat truth: $146,013) | ~6 s |
| Modoc | 8,600 | 8,750 | 17,811 | 8,600 | $60,008 | ~4 s |
| Statewide | 39,288,764 | 39,279,183 | 39,373,659 | 39,287,377 | $112,774 (flat: $112,783) | ~20 s (precompute) |
| Oakland (h8 AOI) | 494,955 | 499,319 | | ~436k ACS | $121,787 | ~6 s |

* **Recommendation:** use `pop_majority`. It dedups by `_cng_fid` and assigns each block group to the AOI by majority of its h10 cells.
* Label income as "population-weighted mean of block-group median household income (ACS 2020–24)". This is NOT the true AOI median; Alameda's true county MHHI is lower, about $130k.
* MHHI is NULL (suppressed) for about 8% of block groups; those are excluded from the income average.
* If a pre-dedup step is ever added, note that a block group spanning two `h0` partitions is handled because `hit` is grouped by `(_cng_fid, h0)` and then summed.

**P1-h10 (optional, accurate for cities): population on an h10 AOI.** Tested on Oakland, it returns 439,418, which matches ACS.
```sql
WITH aoi10 AS MATERIALIZED ({{AOI10}}),   -- SELECT DISTINCT h0, h8, h10 FROM <place/cd/sldl/sldu/tract hex> WHERE ...
hit AS (
  SELECT b._cng_fid, any_value(b.TotPop) AS pop, COUNT(DISTINCT b.h10) AS cells_in
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet') b
  JOIN aoi10 a ON b.h0 = a.h0 AND b.h8 = a.h8 AND b.h10 = a.h10
  GROUP BY b._cng_fid
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi10) AND _cng_fid IN (SELECT _cng_fid FROM hit)
  GROUP BY _cng_fid
)
SELECT SUM(pop) FILTER (WHERE cells_in >= 0.5 * cells_all) AS pop_majority,
       SUM(pop * cells_in / cells_all) AS pop_apportioned
FROM hit JOIN tot USING (_cng_fid)
```

## 4. Health & equity theme

### Datasets inspected
* `park-access-2020-tract-acres-per-thousand`
  * Path: `s3://public-parks/park-access-2020/tract-acres-per-thousand/hex/h0=*/data_0.parquet` (h10)
  * Columns: `GEOID`, `TotPop` (ACS 2014–18), `Park_Acres`, `PPK_tract`, `PPKStatus`.
  * It uses **2010 tracts**: only 6,860 of its 8,036 GEOIDs match 2024 tracts. Use it for aggregates only; do not map it on 2024 tracts.
  * `Park_Acres` includes wilderness. Statewide aggregate acres per 1,000 residents is 1,222 and Modoc is 188,926, so the aggregate ratio is not meaningful. Use the **share of residents in tracts under 3 acres/1,000** instead.
* `park-access-2020-no-park-access`
  * Path: `s3://public-parks/park-access-2020/no-park-access/hex/h0=*/data_0.parquet` (h10)
  * The polygons are the *parts* of block groups more than 1/2 mile from a park. Their h10 footprint is much smaller than the block group.
  * **But `TotPop` and `SqMiles` are WHOLE block-group attributes.** I checked against ACS block-group area and population. Summing `TotPop` therefore gives 21M statewide, which is wrong.
  * Correct use: overlay the no-access h10 cells on ACS block-group h10 cells and apportion block-group population by cell share (uniform density within a block group).
* `park-access-2020-half-mile-access`
  * Path: `s3://public-parks/park-access-2020/half-mile-access/hex/h0=*/data_0.parquet`
  * Native h8 boolean coverage (93k cells). Complementary to no-park-access, but too coarse; I did not use it.
* `ca-dac-eda-2023` (DAC tract)
  * Path: `s3://public-ca-dac/dac-2023/tract/hex/h0=*/data_0.parquet` (h10)
  * Columns: `GEOID20`, `DAC23` (Y / N / 'Data not available'), `Pop23`, `MHI23`.
  * All 9,129 GEOID20 values match census-2024 tract GEOIDs exactly.
* `calenviroscreen-5-0` (draft, Jan 2026)
  * Path: `s3://public-calenviroscreen/calenviroscreen-5-0/ces5/hex/h0=*/data_0.parquet` (h10)
  * Columns: `tract` (FLOAT, must be lpad-ed), `CIscore_Pctl` (0–100, 77 NULL), `Population`.
  * All 9,106 tracts match census-2024 GEOIDs after lpad. They are 2020 tracts, and CA 2024 tracts are identical to them (9,129).

### Proposed metrics
* Headline 1: % of residents more than 1/2 mile from a park (E1a).
* Headline 2: % of residents in DAC tracts (E2).
* Headline 3: population-weighted CES5 percentile, plus % of residents in CES top-25% tracts (E3a).
* Optional headline: % of residents in park-poor tracts (under 3 acres/1,000) (E1b).
* Bar chart A: population by CES5 decile (E3b), with statewide as the comparison (it is flat at about 10% per decile).
* Bar chart B (protected split): share of AOI land in DAC tracts vs. share of AOI GAP 1+2 land in DAC tracts, from E2 (`frac_land_in_dac` vs. `frac_gap12_in_dac`). E2 also returns GAP 1+2 acres per 1,000 residents for DAC vs. non-DAC.

### E1a: residents without a park within 1/2 mile
```sql
WITH aoi AS MATERIALIZED ({{AOI}}),
bgc AS MATERIALIZED (
  SELECT b._cng_fid, b.h0, b.h10, b.TotPop
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet') b
  JOIN aoi a ON b.h0 = a.h0 AND b.h8 = a.h8
),
np AS (
  SELECT DISTINCT n.h0, n.h10
  FROM read_parquet('s3://public-parks/park-access-2020/no-park-access/hex/h0=*/data_0.parquet') n
  JOIN aoi a ON n.h0 = a.h0 AND n.h8 = a.h8
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-census/acs-2020-2024/blockgroup/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi) AND _cng_fid IN (SELECT DISTINCT _cng_fid FROM bgc)
  GROUP BY _cng_fid
),
per_bg AS (
  SELECT bgc._cng_fid, any_value(bgc.TotPop) AS pop,
         COUNT(DISTINCT bgc.h10) AS cells_in, COUNT(DISTINCT np.h10) AS cells_np
  FROM bgc LEFT JOIN np ON bgc.h0 = np.h0 AND bgc.h10 = np.h10
  GROUP BY bgc._cng_fid
)
SELECT SUM(pop * cells_in / cells_all) AS pop_apportioned,
       SUM(pop * cells_np / cells_all) AS pop_no_park_half_mile,
       pop_no_park_half_mile / pop_apportioned AS frac_pop_no_park
FROM per_bg JOIN tot USING (_cng_fid)
WHERE pop IS NOT NULL
```

| AOI | pop (apportioned) | pop with no park ≤ 1/2 mi | frac | time |
|---|---|---|---|---|
| Alameda | 1,676,401 | 111,447 | 6.6% | ~9 s |
| Modoc | 8,750 | 2,978 | 34.0% | ~5 s |
| Statewide | 39,279,183 | 8,653,655 | 22.0% | ~22 s (precompute) |

* The statewide 22% (8.7M) is consistent with the SCORP / Parks for California figure (about 8.9M).
* Caveats:
  * The park buffer is from 2019 (CPAD 2019b) and population is ACS 2020–24.
  * Population is assumed uniform within each block group. This overstates no-access population in large rural block groups.

### E1b: park-poor tracts (SCORP 2020, 2010 tracts)
```sql
WITH aoi AS MATERIALIZED ({{AOI}}),
hit AS MATERIALIZED (
  SELECT p._cng_fid, any_value(p.TotPop) AS pop, any_value(p.Park_Acres) AS park_acres,
         any_value(p.PPK_tract) AS ppk, COUNT(DISTINCT p.h10) AS cells_in
  FROM read_parquet('s3://public-parks/park-access-2020/tract-acres-per-thousand/hex/h0=*/data_0.parquet') p
  JOIN aoi a ON p.h0 = a.h0 AND p.h8 = a.h8
  GROUP BY p._cng_fid
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-parks/park-access-2020/tract-acres-per-thousand/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi) AND _cng_fid IN (SELECT _cng_fid FROM hit)
  GROUP BY _cng_fid
),
tr AS (SELECT * FROM hit JOIN tot USING (_cng_fid) WHERE cells_in >= 0.5 * cells_all)
SELECT COUNT(*) AS n_tracts,
       SUM(pop) AS pop_2018,
       1000 * SUM(park_acres) / SUM(pop) AS park_acres_per_1000,
       COALESCE(SUM(pop) FILTER (WHERE ppk < 3), 0) / SUM(pop) AS frac_pop_under_3_acres,
       quantile_cont(ppk, 0.5) FILTER (WHERE pop > 0) AS median_tract_ppk
FROM tr
```

| AOI | n_tracts | pop (2018) | acres/1,000 (aggregate) | % pop in tracts < 3 ac/1,000 | median tract | time |
|---|---|---|---|---|---|---|
| Alameda | 363 | 1,651,576 | 43.3 | 65.8% | 1.34 | ~5 s |
| Modoc | 4 | 8,938 | 188,926 | 0% | 218,536 | ~4 s |
| Statewide | 8,034 | 39,148,353 | 1,222 | 61.0% | 1.57 | ~15 s |

* Recommendation: use `frac_pop_under_3_acres` as the metric. The aggregate acres/1,000 is dominated by wilderness.

### E2: DAC population, and protected land in DAC vs. non-DAC tracts
```sql
WITH aoi AS MATERIALIZED ({{AOI}}),
dacc AS MATERIALIZED (
  SELECT d._cng_fid, d.h0, d.h8, d.h10, d.DAC23, d.Pop23
  FROM read_parquet('s3://public-ca-dac/dac-2023/tract/hex/h0=*/data_0.parquet') d
  JOIN aoi a ON d.h0 = a.h0 AND d.h8 = a.h8
),
cellfrac AS (
  SELECT h0, h8, COUNT(DISTINCT h10) FILTER (WHERE DAC23 = 'Y') / COUNT(DISTINCT h10) AS dac_frac
  FROM dacc GROUP BY h0, h8
),
land AS (
  SELECT e.h0, e.h8, e.land_area_km2
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet') e
  JOIN aoi a ON e.h0 = a.h0 AND e.h8 = a.h8
),
landstats AS (
  SELECT SUM(l.land_area_km2) AS land_km2,
         SUM(l.land_area_km2 * COALESCE(c.dac_frac, 0)) AS dac_land_km2,
         SUM(l.land_area_km2 * COALESCE(w.w1 + w.w2, 0)) AS gap12_km2,
         SUM(l.land_area_km2 * COALESCE(w.w1 + w.w2, 0) * COALESCE(c.dac_frac, 0)) AS gap12_dac_km2
  FROM land l
  LEFT JOIN read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights-res8/h0=*/data_0.parquet') w
    ON w.h0 = l.h0 AND w.h8 = l.h8
  LEFT JOIN cellfrac c ON c.h0 = l.h0 AND c.h8 = l.h8
),
hit AS (
  SELECT _cng_fid, any_value(DAC23) AS dac, any_value(Pop23) AS pop, COUNT(DISTINCT h10) AS cells_in
  FROM dacc GROUP BY _cng_fid
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-ca-dac/dac-2023/tract/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi) AND _cng_fid IN (SELECT _cng_fid FROM hit)
  GROUP BY _cng_fid
),
popstats AS (
  SELECT SUM(pop) AS pop_total,
         COALESCE(SUM(pop) FILTER (WHERE dac = 'Y'), 0) AS pop_dac,
         COUNT(*) AS n_tracts,
         COUNT(*) FILTER (WHERE dac = 'Y') AS n_dac_tracts
  FROM hit JOIN tot USING (_cng_fid)
  WHERE cells_in >= 0.5 * cells_all
)
SELECT p.n_tracts, p.n_dac_tracts, p.pop_total, p.pop_dac,
       p.pop_dac / p.pop_total AS frac_pop_in_dac,
       l.dac_land_km2 / l.land_km2 AS frac_land_in_dac,
       l.gap12_dac_km2 / NULLIF(l.gap12_km2, 0) AS frac_gap12_in_dac,
       247.105 * l.gap12_dac_km2 / NULLIF(p.pop_dac, 0) * 1000 AS gap12_acres_per_1000_dac,
       247.105 * (l.gap12_km2 - l.gap12_dac_km2) / NULLIF(p.pop_total - p.pop_dac, 0) * 1000 AS gap12_acres_per_1000_nondac
FROM popstats p, landstats l
```

| AOI | tracts (DAC) | pop (ACS 19–23) | pop DAC | % pop DAC | % land in DAC | % GAP1+2 land in DAC | GAP1+2 ac/1,000 DAC | ac/1,000 non-DAC | time |
|---|---|---|---|---|---|---|---|---|---|
| Alameda | 382 (53) | 1,659,188 | 213,041 | 12.8% | 1.5% | 0.002% | 0.009 | 58.7 | ~7 s (48 s without MATERIALIZED) |
| Modoc | 4 (4) | 8,646 | 8,646 | 100% | 100% | 100% | 18,434 | NULL | ~5 s |
| Statewide | 9,110 (2,896) | 39,242,062 | 11,865,859 | 30.2% | 64.0% | 72.7% | 1,624 | 265 | ~11 s |

* Caveats:
  * DAC here is DWR's income-only definition: MHI below 80% of the statewide figure, ACS 2019–23. It is not SB 535 CalEnviroScreen DAC.
  * DAC share within an h8 cell comes from h10 counts, and GAP and DAC are assumed independent within each h8 cell (a fine-grained approximation).
  * Statewide, large rural DAC tracts dominate the land shares. The "acres per 1,000" split therefore says more about rural vs. urban than about access, so present it with care, or show only the two shares in the bar chart.
  * Tracts with 'Data not available' count as non-DAC.

### E3a: CES5 headline
```sql
WITH aoi AS MATERIALIZED ({{AOI}}),
hit AS MATERIALIZED (
  SELECT c._cng_fid, any_value(c.CIscore_Pctl) AS pctl, any_value(c.Population) AS pop, COUNT(DISTINCT c.h10) AS cells_in
  FROM read_parquet('s3://public-calenviroscreen/calenviroscreen-5-0/ces5/hex/h0=*/data_0.parquet') c
  JOIN aoi a ON c.h0 = a.h0 AND c.h8 = a.h8
  GROUP BY c._cng_fid
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-calenviroscreen/calenviroscreen-5-0/ces5/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi) AND _cng_fid IN (SELECT _cng_fid FROM hit)
  GROUP BY _cng_fid
),
tr AS (
  SELECT pctl, pop FROM hit JOIN tot USING (_cng_fid)
  WHERE cells_in >= 0.5 * cells_all AND pctl IS NOT NULL AND NOT isnan(pctl)
)
SELECT COUNT(*) AS n_tracts_scored,
       SUM(pop) AS pop,
       SUM(pctl * pop) / SUM(pop) AS ces_pctl_popweighted,
       COALESCE(SUM(pop) FILTER (WHERE pctl >= 75), 0) / SUM(pop) AS frac_pop_ces_top25
FROM tr
```

| AOI | tracts scored | pop | pop-weighted CES pctl | % pop in CES top 25% | time |
|---|---|---|---|---|---|
| Alameda | 379 | 1,659,179 | 40.9 | 9.1% | ~5 s |
| Modoc | 4 | 8,646 | 42.8 | 0% | ~4 s |
| Statewide | 9,029 | 39,120,359 | 50.5 | 24.8% | ~10 s |

### E3b: bar chart, population by CES5 decile (always returns 10 rows)
```sql
WITH aoi AS MATERIALIZED ({{AOI}}),
hit AS MATERIALIZED (
  SELECT c._cng_fid, any_value(c.CIscore_Pctl) AS pctl, any_value(c.Population) AS pop, COUNT(DISTINCT c.h10) AS cells_in
  FROM read_parquet('s3://public-calenviroscreen/calenviroscreen-5-0/ces5/hex/h0=*/data_0.parquet') c
  JOIN aoi a ON c.h0 = a.h0 AND c.h8 = a.h8
  GROUP BY c._cng_fid
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-calenviroscreen/calenviroscreen-5-0/ces5/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi) AND _cng_fid IN (SELECT _cng_fid FROM hit)
  GROUP BY _cng_fid
),
tr AS (
  SELECT pctl, pop FROM hit JOIN tot USING (_cng_fid)
  WHERE cells_in >= 0.5 * cells_all AND pctl IS NOT NULL AND NOT isnan(pctl)
),
bins AS (
  SELECT LEAST(CAST(floor(pctl / 10) AS INT), 9) * 10 AS decile_lo, COUNT(*) AS n_tracts, SUM(pop) AS pop
  FROM tr GROUP BY 1
)
SELECT r.range AS decile_lo,
       CAST(r.range AS VARCHAR) || '-' || CAST(r.range + 10 AS VARCHAR) AS label,
       COALESCE(b.n_tracts, 0) AS n_tracts,
       COALESCE(b.pop, 0) AS pop,
       COALESCE(b.pop, 0) / (SELECT SUM(pop) FROM tr) AS frac_pop
FROM range(0, 100, 10) r
LEFT JOIN bins b ON b.decile_lo = r.range
ORDER BY 1
```

Share of population by decile (0–10 through 90–100):

| AOI | 0–10 | 10–20 | 20–30 | 30–40 | 40–50 | 50–60 | 60–70 | 70–80 | 80–90 | 90–100 |
|---|---|---|---|---|---|---|---|---|---|---|
| Alameda | 10.0 | 13.3 | 15.0 | 12.6 | 11.8 | 12.5 | 11.4 | 6.4 | 5.5 | 1.4 |
| Modoc | 0 | 0 | 0 | 64.1 | 0 | 35.9 | 0 | 0 | 0 | 0 |
| Statewide | 9.4 | 9.6 | 9.8 | 10.1 | 10.2 | 10.3 | 10.6 | 10.2 | 10.1 | 9.7 |

Alameda and Modoc ran in about 5 s; statewide in about 10 s.

## 5. M1: tract map layer (GEOID → CES5 percentile), one JSON row

```sql
WITH aoi AS MATERIALIZED ({{AOI}}),
hit AS MATERIALIZED (
  SELECT c._cng_fid, any_value(c.tract) AS tract, any_value(c.CIscore_Pctl) AS ces_pctl, COUNT(DISTINCT c.h10) AS cells_in
  FROM read_parquet('s3://public-calenviroscreen/calenviroscreen-5-0/ces5/hex/h0=*/data_0.parquet') c
  JOIN aoi a ON c.h0 = a.h0 AND c.h8 = a.h8
  GROUP BY c._cng_fid
),
tot AS (
  SELECT _cng_fid, COUNT(DISTINCT h10) AS cells_all
  FROM read_parquet('s3://public-calenviroscreen/calenviroscreen-5-0/ces5/hex/h0=*/data_0.parquet')
  WHERE h0 IN (SELECT DISTINCT h0 FROM aoi) AND _cng_fid IN (SELECT _cng_fid FROM hit)
  GROUP BY _cng_fid
),
rows AS (
  SELECT lpad(CAST(CAST(tract AS BIGINT) AS VARCHAR), 11, '0') AS GEOID, round(ces_pctl, 1) AS value
  FROM hit JOIN tot USING (_cng_fid)
  WHERE cells_in >= 0.5 * cells_all
)
SELECT COUNT(*) AS n,
       CAST(to_json(map_from_entries(list((GEOID, value) ORDER BY GEOID))) AS VARCHAR) AS j
FROM rows
```
* Output: `n`, and `j` (a JSON object mapping GEOID to CES percentile; NULL for the 77 unscored tracts).
* Results:
  * Modoc: `{"06049000100":56.3,"06049000200":32.6,"06049000300":39.1,"06049000400":30.8}`
  * LA County: 2,505 tracts, 47.5 KB, about 5 s. A handful are cross-boundary false positives from 06059 and 06111.
  * Alameda: about 382 tracts.
* **Tract IDs match.** All CES5 tracts (after lpad) and all DAC `GEOID20` values are present in census-2024 tract GEOIDs, because CA 2020 tracts and 2024 tracts are identical.
* So color the census tract PMTiles with a MapLibre `match` on `GEOID`, built from `j`:
  * URL: `https://s3-west.nrp-nautilus.io/public-census/census-2024/tract.pmtiles`
  * source-layer: `tract`
  * property: `GEOID`
* Do NOT use the CES PMTiles keyed on `tract`: it is a float, with no leading zero.
* Do not map SCORP park-tract values on these tiles; they use 2010 tracts.
* Swapping in another value is a one-line change, for example `DAC23` from the DAC tract hex (`GEOID20`), or `MHI23`.
