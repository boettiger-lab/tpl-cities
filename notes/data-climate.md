# Recon: CLIMATE RISK theme (no-LLM CA dashboard)

All templates tested via the `duckdb-geo` MCP server over HTTP (`https://duckdb-mcp.nrp-nautilus.io/mcp`, `tools/call query`), timed end-to-end wall clock from this client.
Runtimes are noisy: the server was shared with other agents during testing; the same query varied 10 s to 58 s between runs. The numbers below are the last clean run.
SQL files: `sql-climate/climate_*.sql` (test harness: `mcpq.py <file> [alameda|modoc|state]`).

## Contract / global findings (read first)

1. **The statewide AOI given in the brief does not work.** `read_parquet('https://s3-west.nrp-nautilus.io/...h0=*/...')` errors with *"Globs (`*`) for generic HTTP file is are not supported"*. Use the s3:// form:
   `SELECT DISTINCT h0, h8 FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet')` (525,034 cells, 410,641 km²). The same applies to every https path in STAC descriptions: use `s3://public-ca30x30/...` etc.
2. **Performance rule that matters most:** join *every* big `read_parquet` directly to `aoi` in its own CTE (`JOIN aoi a ON x.h0=a.h0 AND x.h8=a.h8`), then join the small CTEs to each other. If you chain one big file onto a CTE that came from another big file, partition pruning stops working. The CHELSA heat query took 21–44 s chained and 6–8 s restructured; the 9-scenario chart took 120–140 s chained and 10–37 s restructured. All templates below follow this pattern.
3. Protected = GAP 1+2 = `w1+w2` from conserved-areas-terrestrial-2025 hex-weights, LEFT JOIN + COALESCE 0. Res-10 data (flood, SLR, fire) joins the **res-10** weights asset (`hex-weights`, has h8 for the aoi join). Res-9 data joins `hex-weights-res9`, and res-8 data joins `hex-weights-res8`. This gives an exact split at the data's own resolution rather than assuming independence inside an h8 cell. Protected share = Σ(area·hazard·pw)/Σ(area·pw), and unprotected = Σ(area·hazard·(1−pw))/Σ(area·(1−pw)).
4. The land denominator is the ca30x30-ecoregion grid (res-10 `hex` for res-10 data, and `hex-res8` `land_area_km2` / `hex-res9` otherwise). It is "land/water agnostic" and includes some open water, such as parts of SF Bay. The flood/SLR query therefore drops cells that FEMA maps entirely as `OPEN WATER`. This took Alameda from 2,239 to 2,051 km².
5. County AOIs include the whole h8 cells that touch the boundary, so they spill slightly into neighboring counties. For example, Alameda's land is 2,051 km² against Census ALAND of 1,914 km². This comes from the AOI contract, not from these queries.

---

## Q1 `climate_water_hazard`: FEMA 100-yr / 500-yr floodplain + NOAA 5 ft sea-level rise
One row: share of AOI land in the FEMA SFHA (100-yr), in SFHA + 0.2% (500-yr, cumulative), and in the NOAA 5 ft SLR inundation, each split protected/unprotected.

Datasets: `flood-hazard` hex res10 `s3://public-hazard/flood-hazard/hex/h0=*/data_0.parquet` (FLD_ZONE values: A, A99, AE, AH, AO, V, VE = SFHA (`SFHA_TF='T'`); X with `ZONE_SUBTY='0.2 PCT ANNUAL CHANCE FLOOD HAZARD'` = 500-yr band; also X minimal, `X AREA WITH REDUCED FLOOD RISK DUE TO LEVEE`, D, OPEN WATER, AREA NOT INCLUDED). `sea-level-rise` hex res10 `s3://public-hazard/sea-level-rise/hex/h0=*/data_0.parquet` (5 ft only, `state='CA'`).

```sql
WITH aoi AS ({{AOI}}),
land10 AS (            -- CA land reference grid (res 10) inside the AOI
  SELECT DISTINCT e.h0, e.h10
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex/h0=*/data_0.parquet') e
  JOIN aoi a ON e.h0 = a.h0 AND e.h8 = a.h8
),
prot10 AS (            -- GAP 1+2 share per res-10 cell (only conserved-touching cells have rows)
  SELECT w.h0, w.h10, w.w1 + w.w2 AS pw
  FROM read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights/h0=*/data_0.parquet') w
  JOIN aoi a ON w.h0 = a.h0 AND w.h8 = a.h8
),
fl AS (                -- FEMA NFHL flags per res-10 cell
  SELECT f.h0, f.h10,
         MAX(CASE WHEN f.SFHA_TF = 'T' THEN 1 ELSE 0 END) AS in100,
         MAX(CASE WHEN f.SFHA_TF = 'T' OR f.ZONE_SUBTY = '0.2 PCT ANNUAL CHANCE FLOOD HAZARD' THEN 1 ELSE 0 END) AS in500,
         MIN(CASE WHEN f.FLD_ZONE = 'OPEN WATER' THEN 1 ELSE 0 END) AS water
  FROM read_parquet('s3://public-hazard/flood-hazard/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  GROUP BY f.h0, f.h10
),
slr AS (               -- NOAA 5 ft sea-level-rise inundation
  SELECT DISTINCT s.h0, s.h10
  FROM read_parquet('s3://public-hazard/sea-level-rise/hex/h0=*/data_0.parquet') s
  JOIN aoi a ON s.h0 = a.h0 AND s.h8 = a.h8
  WHERE s.state = 'CA'
),
cells AS (
  SELECT h3_cell_area(l.h10, 'km^2') AS a10,
         COALESCE(fl.in100, 0) AS in100,
         COALESCE(fl.in500, 0) AS in500,
         CASE WHEN s.h10 IS NULL THEN 0 ELSE 1 END AS inslr,
         COALESCE(p.pw, 0) AS pw
  FROM land10 l
  LEFT JOIN fl     ON l.h0 = fl.h0 AND l.h10 = fl.h10
  LEFT JOIN slr s  ON l.h0 = s.h0  AND l.h10 = s.h10
  LEFT JOIN prot10 p ON l.h0 = p.h0 AND l.h10 = p.h10
  WHERE COALESCE(fl.water, 0) = 0          -- drop FEMA open-water cells (SF Bay, lakes)
)
SELECT
  SUM(a10)                                                       AS land_km2,
  SUM(a10 * in100) / SUM(a10)                                    AS fld100_share,
  SUM(a10 * in500) / SUM(a10)                                    AS fld500_share,
  SUM(a10 * inslr) / SUM(a10)                                    AS slr5ft_share,
  SUM(a10 * in100)                                               AS fld100_km2,
  SUM(a10 * in500)                                               AS fld500_km2,
  SUM(a10 * inslr)                                               AS slr5ft_km2,
  SUM(a10 * in100 * pw)       / NULLIF(SUM(a10 * pw), 0)         AS fld100_share_protected,
  SUM(a10 * in100 * (1 - pw)) / NULLIF(SUM(a10 * (1 - pw)), 0)   AS fld100_share_unprotected,
  SUM(a10 * in500 * pw)       / NULLIF(SUM(a10 * pw), 0)         AS fld500_share_protected,
  SUM(a10 * in500 * (1 - pw)) / NULLIF(SUM(a10 * (1 - pw)), 0)   AS fld500_share_unprotected,
  SUM(a10 * inslr * pw)       / NULLIF(SUM(a10 * pw), 0)         AS slr5ft_share_protected,
  SUM(a10 * inslr * (1 - pw)) / NULLIF(SUM(a10 * (1 - pw)), 0)   AS slr5ft_share_unprotected
FROM cells
```
Columns: land_km2, fld100_share, fld500_share, slr5ft_share, fld100_km2, fld500_km2, slr5ft_km2, fld100_share_protected, fld100_share_unprotected, fld500_share_protected, fld500_share_unprotected, slr5ft_share_protected, slr5ft_share_unprotected

| AOI | land km² | 100-yr | 500-yr | SLR 5ft | 100-yr prot / unprot | 500-yr prot / unprot | SLR prot / unprot | runtime |
|---|---|---|---|---|---|---|---|---|
| Alameda | 2,051 | 10.4% (214 km²) | 13.5% (276) | 9.5% (195) | 24.2% / 7.7% | 24.3% / 11.3% | 24.0% / 6.7% | 12–15 s |
| Modoc | 10,969 | 10.9% (1,195) | 10.9% (1,200) | 0 | 27.2% / 9.9% | 27.7% / 9.9% | 0 / 0 | 10–22 s |
| Statewide | 409,888 | 7.2% (29,704) | 8.4% (34,576) | 0.69% (2,831) | 4.5% / 8.2% | 4.7% / 9.7% | 0.59% / 0.73% | 28–41 s |

Caveats: FEMA mapping coverage is about 100% of CA land (99.7% statewide counting all zones except AREA NOT INCLUDED; zone D "undetermined" counts as not-SFHA). A cell counts as hazardous if any part of it is mapped in the zone; at res-10 (about 1.5 ha) this is an exact enough area. Levee-protected X counts as not-SFHA. In Alameda the SLR footprint is mostly baylands (salt ponds, Don Edwards refuge), which is why protected land shows higher exposure. Modoc's high share comes from A zones around lakes and wetlands. A flood-only variant (drop the `slr` CTE) gives the same numbers.

---

## Q2 `climate_fire_summary`: wildfire burned area 2021–2025 + prescribed burns, protected split
One row. Data: `calfire-2025-firep` hex res10 (`YEAR_` runs through 2025; window 2021–2025) and `calfire-2025-rxburn` hex res10. calfire-2024-rxburn stops at 2024, so the 2025 release is used. Area = Σ h3_cell_area(h10)·247.105 over distinct burned cells.

```sql
WITH aoi AS ({{AOI}}),
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
```
Columns: burned_ac_unique (each cell once), burned_ac_incl_reburn (cell counted once per year it burned), burned_ac_protected, burned_ac_unprotected, rx_ac_unique, rx_ac_protected, burned_share, burned_share_protected, burned_share_unprotected, rx_share, land_ac, prot_ac

| AOI | burned ac (unique) | incl. reburn | share of land | prot / unprot share | Rx ac (unique) | runtime |
|---|---|---|---|---|---|---|
| Alameda | 2,387 | 2,496 | 0.43% | 1.55% / 0.23% | 0 | 10–13 s |
| Modoc | 18,746 | 18,824 | 0.69% | 0.08% / 0.73% | 24,651 (6,099 protected) | 7–11 s |
| Statewide | 4,655,182 | 4,667,409 | 4.59% | 4.71% / 4.54% | 479,834 (100,800 protected) | 9–16 s |

Caveats: the statewide unique figure (4.66 M ac) matches the sum of FRAP GIS_ACRES for 2021–2025 (4.70 M). The hex layer omits fires smaller than one res-10 cell. Perimeters include unburned islands. The Rx hex omits 583 sub-cell treatments, and units are treated footprint, not TREATED_AC.

---

## Q3 `climate_fire_by_year`: bar chart, wildfire vs prescribed-burn acres by year
5 rows (2021–2025), zero-filled.

```sql
WITH aoi AS ({{AOI}}),
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
SELECT y.yr AS year,
       COALESCE((SELECT SUM(h3_cell_area(h10, 'km^2')) FROM wf WHERE wf.yr = y.yr), 0) * 247.105 AS wildfire_ac,
       COALESCE((SELECT SUM(h3_cell_area(h10, 'km^2')) FROM rx WHERE rx.yr = y.yr), 0) * 247.105 AS rx_burn_ac
FROM yrs y
ORDER BY y.yr
```
Columns: year, wildfire_ac, rx_burn_ac

| year | Alameda wf / rx | Modoc wf / rx | Statewide wf / rx |
|---|---|---|---|
| 2021 | 0 / 0 | 1,795 / 3,461 | 2,497,560 / 82,822 |
| 2022 | 1,114 / 0 | 6,137 / 2,578 | 323,439 / 105,576 |
| 2023 | 0 / 0 | 93 / 8,716 | 326,180 / 155,785 |
| 2024 | 1,285 / 0 | 6,532 / 7,967 | 1,010,038 / 129,384 |
| 2025 | 97 / 0 | 4,266 / 4,232 | 510,191 / 91,943 |

Runtime 4–5 s for each AOI. In this chart a cell is counted once per year, so the bars add up to the "incl. reburn" figure, not the unique one.

---

## Q4 `climate_heat`: CHELSA 2.1 warming of the hottest month (BIO5), headline
What exists (all hex res-8, already joined on h8/h0, values in **°C, already unscaled**, no K×10):
- Baseline `chelsa-2-1-baseline-1981-2010`: `s3://public-bioclimate/chelsa-2-1/baseline-1981-2010/hex/h0=*/data_0.parquet`. Columns bio1, bio4, bio5, bio6, bio12, bio15, bio17 (no bio10, so there is no warmest-quarter mean).
- Futures `s3://public-bioclimate/chelsa-2-1/{ssp126|ssp370|ssp585}-{2011-2040|2041-2070|2071-2100}/hex/h0=*/data_0.parquet` (9 collections, `chelsa-2-1-<ssp>-<period>`). Each variable has 5 GCM columns (`_gfdl_esm4, _ipsl_cm6a_lr, _mpi_esm1_2_hr, _mri_esm2_0, _ukesm1_0_ll`) plus `_median, _min, _max`.
- **Default: SSP3-7.0, 2041–2070, BIO5 (`bio5_median − bio5`)**, area-weighted by ecoregion `land_area_km2`. The min/max across cells gives the spatial range, and `bio5_min`/`bio5_max` give the GCM spread.

```sql
WITH aoi AS ({{AOI}}),
land AS (
  SELECT e.h0, e.h8, e.land_area_km2 AS wt
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet') e
  JOIN aoi a ON e.h0 = a.h0 AND e.h8 = a.h8
),
prot AS (
  SELECT w.h0, w.h8, w.w1 + w.w2 AS pw
  FROM read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights-res8/h0=*/data_0.parquet') w
  JOIN aoi a ON w.h0 = a.h0 AND w.h8 = a.h8
),
base AS (
  SELECT b.h0, b.h8, b.bio1, b.bio5
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/baseline-1981-2010/hex/h0=*/data_0.parquet') b
  JOIN aoi a ON b.h0 = a.h0 AND b.h8 = a.h8
),
fut AS (   -- default scenario: SSP3-7.0, 2041-2070, 5-GCM median
  SELECT f.h0, f.h8, f.bio1_median, f.bio5_median, f.bio5_min, f.bio5_max
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/ssp370-2041-2070/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
),
c AS (
  SELECT l.wt, COALESCE(p.pw, 0) AS pw,
         b.bio5 AS bio5_base, f.bio5_median AS bio5_fut,
         f.bio5_median - b.bio5 AS d5,
         f.bio5_min    - b.bio5 AS d5_lo,
         f.bio5_max    - b.bio5 AS d5_hi,
         f.bio1_median - b.bio1 AS d1
  FROM land l
  JOIN base b ON l.h0 = b.h0 AND l.h8 = b.h8
  JOIN fut  f ON l.h0 = f.h0 AND l.h8 = f.h8
  LEFT JOIN prot p ON l.h0 = p.h0 AND l.h8 = p.h8
  WHERE NOT isnan(b.bio5) AND NOT isnan(f.bio5_median)
)
SELECT
  SUM(wt * bio5_base) / SUM(wt)  AS bio5_baseline_c,
  SUM(wt * bio5_fut)  / SUM(wt)  AS bio5_future_c,
  SUM(wt * d5) / SUM(wt)         AS bio5_increase_c,
  MIN(d5)                        AS bio5_increase_min_c,
  MAX(d5)                        AS bio5_increase_max_c,
  SUM(wt * d5_lo) / SUM(wt)      AS bio5_increase_model_lo_c,
  SUM(wt * d5_hi) / SUM(wt)      AS bio5_increase_model_hi_c,
  SUM(wt * d1) / SUM(wt)         AS bio1_increase_c,
  SUM(wt * pw * d5)       / NULLIF(SUM(wt * pw), 0)       AS bio5_increase_protected_c,
  SUM(wt * (1 - pw) * d5) / NULLIF(SUM(wt * (1 - pw)), 0) AS bio5_increase_unprotected_c,
  COUNT(*) AS n_cells
FROM c
```
Columns: bio5_baseline_c, bio5_future_c, bio5_increase_c, bio5_increase_min_c, bio5_increase_max_c (spatial range across AOI cells), bio5_increase_model_lo_c, bio5_increase_model_hi_c (coolest/warmest GCM, area-mean), bio1_increase_c, bio5_increase_protected_c, bio5_increase_unprotected_c, n_cells

| AOI | BIO5 base → future (°C) | increase mean [cell range] | GCM range | BIO1 increase | prot / unprot | runtime |
|---|---|---|---|---|---|---|
| Alameda | 28.6 → 30.4 | +1.71 [1.50–1.90] | 1.27–4.11 | +1.75 | 1.69 / 1.71 | 6 s |
| Modoc | 29.2 → 32.3 | +3.14 [2.90–3.30] | 2.14–5.99 | +2.32 | 3.19 / 3.13 | 6 s |
| Statewide | 31.9 → 34.3 | +2.41 [1.30–3.30] | 1.69–4.17 | +2.15 | 2.39 / 2.41 | 8 s |

Caveats: 1-pixel coastal cells with no CHELSA value are dropped (statewide n = 521,974 of 525,034). The change field is smooth (GCM anomaly), so values hardly vary within a county. The protected/unprotected split is near-identical and probably not worth showing.

## Q5 `climate_heat_scenarios`: bar chart, BIO5 increase by scenario × period
6 rows (SSP1-2.6/3-7.0/5-8.5 × 2041–2070, 2071–2100). Drop the period you do not want to make it faster. The 2011–2040 period also exists.

```sql
WITH aoi AS ({{AOI}}),
land AS (
  SELECT e.h0, e.h8, e.land_area_km2 AS wt
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res8/h0=*/data_0.parquet') e
  JOIN aoi a ON e.h0 = a.h0 AND e.h8 = a.h8
),
base AS (
  SELECT b.h0, b.h8, b.bio5
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/baseline-1981-2010/hex/h0=*/data_0.parquet') b
  JOIN aoi a ON b.h0 = a.h0 AND b.h8 = a.h8
  WHERE NOT isnan(b.bio5)
),
fut AS (
  SELECT 'ssp126' AS scenario, '2041-2070' AS period, f.h0, f.h8, f.bio5_median
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/ssp126-2041-2070/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  UNION ALL
  SELECT 'ssp370' AS scenario, '2041-2070' AS period, f.h0, f.h8, f.bio5_median
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/ssp370-2041-2070/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  UNION ALL
  SELECT 'ssp585' AS scenario, '2041-2070' AS period, f.h0, f.h8, f.bio5_median
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/ssp585-2041-2070/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  UNION ALL
  SELECT 'ssp126' AS scenario, '2071-2100' AS period, f.h0, f.h8, f.bio5_median
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/ssp126-2071-2100/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  UNION ALL
  SELECT 'ssp370' AS scenario, '2071-2100' AS period, f.h0, f.h8, f.bio5_median
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/ssp370-2071-2100/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  UNION ALL
  SELECT 'ssp585' AS scenario, '2071-2100' AS period, f.h0, f.h8, f.bio5_median
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/ssp585-2071-2100/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
)
SELECT f.scenario, f.period,
       SUM(l.wt * (f.bio5_median - b.bio5)) / SUM(l.wt) AS bio5_increase_c
FROM fut f
JOIN base b ON f.h0 = b.h0 AND f.h8 = b.h8
JOIN land l ON f.h0 = l.h0 AND f.h8 = l.h8
WHERE NOT isnan(f.bio5_median)
GROUP BY f.scenario, f.period
ORDER BY f.period, f.scenario
```
Columns: scenario, period, bio5_increase_c

| scenario | period | Alameda | Modoc | Statewide |
|---|---|---|---|---|
| ssp126 | 2041-2070 | 1.80 | 2.16 | 1.94 |
| ssp370 | 2041-2070 | 1.71 | 3.14 | 2.41 |
| ssp585 | 2041-2070 | 2.33 | 3.27 | 2.67 |
| ssp126 | 2071-2100 | 1.34 | 1.98 | 1.71 |
| ssp370 | 2071-2100 | 2.99 | 4.33 | 3.54 |
| ssp585 | 2071-2100 | 4.19 | 5.27 | 4.67 |

Runtime: Alameda 15 s, Modoc 10 s, statewide 37 s. (For reference, 2011–2040: Alameda 1.27/1.11/1.32, Modoc 1.80/1.84/1.61, state 1.44/1.53/1.56.)

---

## Q6 `climate_habitat_exposure`: mid-century habitat climate exposure (Thorne et al. 2016), 30x30 convention
One row: share of **natural habitat** projected climate-exposed by 2040–2069, for MIROC5 (hot-dry) and CNRM-CM5 (warm-wet), split protected/unprotected. Convention from ca-30x30/system-prompt.md: mask non-natural land, then treat values `< 0` or `≥ 0.95` as exposed. Non-natural is masked with `cwhr13` hex-fractions, excluding whr13num 0 (nodata), 10 (agriculture), 80 (urban) and 90 (water); this mask is my choice, because the repo does not define "non-natural". The exposure hex is res-9 (`s3://public-hazard/mid-century-habitat-climate-exposure/{miroc|cnrm}/hex/h0=*/data_0.parquet`). Observed values run 0.05–1.0 and none are negative, so the `< 0` arm never fires.

```sql
WITH aoi AS ({{AOI}}),
nat9 AS (       -- natural-habitat area per res-9 cell (CWHR13 minus agriculture, urban, water, nodata)
  SELECT v.h0, v.h9, SUM(v.frac * h3_cell_area(v.h10, 'km^2')) AS nat_km2
  FROM read_parquet('s3://public-ca30x30/cwhr13/hex-fractions/h0=*/data_0.parquet') v
  JOIN aoi a ON v.h0 = a.h0 AND v.h8 = a.h8
  WHERE v.whr13num NOT IN (0, 10, 80, 90)
  GROUP BY v.h0, v.h9
),
miroc AS (      -- MIROC5 (hot-dry)
  SELECT x.h0, x.h9, x.exposure
  FROM read_parquet('s3://public-hazard/mid-century-habitat-climate-exposure/miroc/hex/h0=*/data_0.parquet') x
  JOIN aoi a ON x.h0 = a.h0 AND x.h8 = a.h8
),
cnrm AS (       -- CNRM-CM5 (warm-wet)
  SELECT x.h0, x.h9, x.exposure
  FROM read_parquet('s3://public-hazard/mid-century-habitat-climate-exposure/cnrm/hex/h0=*/data_0.parquet') x
  JOIN aoi a ON x.h0 = a.h0 AND x.h8 = a.h8
),
prot9 AS (
  SELECT w.h0, w.h9, w.w1 + w.w2 AS pw
  FROM read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights-res9/h0=*/data_0.parquet') w
  JOIN aoi a ON w.h0 = a.h0 AND w.h8 = a.h8
),
c AS (
  SELECT n.nat_km2 AS a,
         CASE WHEN m.exposure < 0 OR m.exposure >= 0.95 THEN 1 ELSE 0 END AS exp_miroc,
         CASE WHEN c.exposure < 0 OR c.exposure >= 0.95 THEN 1 ELSE 0 END AS exp_cnrm,
         COALESCE(p.pw, 0) AS pw
  FROM nat9 n
  JOIN miroc m ON n.h0 = m.h0 AND n.h9 = m.h9
  LEFT JOIN cnrm c ON n.h0 = c.h0 AND n.h9 = c.h9
  LEFT JOIN prot9 p ON n.h0 = p.h0 AND n.h9 = p.h9
  WHERE NOT isnan(m.exposure)
)
SELECT
  SUM(a)                                                       AS natural_habitat_km2,
  SUM(a * exp_miroc) / SUM(a)                                  AS exposed_share_hotdry,
  SUM(a * exp_cnrm)  / SUM(a)                                  AS exposed_share_warmwet,
  SUM(a * exp_miroc * pw)       / NULLIF(SUM(a * pw), 0)       AS exposed_share_hotdry_protected,
  SUM(a * exp_miroc * (1 - pw)) / NULLIF(SUM(a * (1 - pw)), 0) AS exposed_share_hotdry_unprotected,
  SUM(a * exp_cnrm * pw)        / NULLIF(SUM(a * pw), 0)       AS exposed_share_warmwet_protected,
  SUM(a * exp_cnrm * (1 - pw))  / NULLIF(SUM(a * (1 - pw)), 0) AS exposed_share_warmwet_unprotected
FROM c
```
Columns: natural_habitat_km2, exposed_share_hotdry, exposed_share_warmwet, exposed_share_hotdry_protected, exposed_share_hotdry_unprotected, exposed_share_warmwet_protected, exposed_share_warmwet_unprotected

| AOI | natural km² | exposed hot-dry | exposed warm-wet | hot-dry prot / unprot | warm-wet prot / unprot | runtime |
|---|---|---|---|---|---|---|
| Alameda | 1,240 | 0.10% | 1.2% | 0.26% / 0.06% | 3.1% / 0.76% | 6 s |
| Modoc | 9,714 | 44.3% | 41.4% | 25.6% / 45.3% | 35.6% / 41.7% | 6 s |
| Statewide | 336,783 | 21.2% | 23.7% | 22.1% / 20.8% | 22.0% / 24.4% | 9 s |

Caveats: the source raster is 90 m; the hex stores a res-9 **mean**, so thresholding at ≥ 0.95 undercounts mixed cells. Unmasked (all cells with a value), statewide is 28.8% / 31.2%. The license is unconfirmed according to STAC. This is a strong differentiator (Modoc vs Alameda) and fits a "climate risk to nature" framing.

---

## Q7 `climate_whp`: wildfire hazard potential (USFS WHP 2023, classified), quick extra indicator
One row: share of land in High/Very High WHP (classes 4–5), with protected split. `s3://public-fire/whp-2023-classified-conus/hex/h0=*/data_0.parquet` (res-9 mode). Denominator: ecoregion `hex-res9` land_area_km2.

```sql
WITH aoi AS ({{AOI}}),
whp AS (
  SELECT x.h0, x.h9, x.whp_class
  FROM read_parquet('s3://public-fire/whp-2023-classified-conus/hex/h0=*/data_0.parquet') x
  JOIN aoi a ON x.h0 = a.h0 AND x.h8 = a.h8
),
land9 AS (
  SELECT e.h0, e.h9, e.land_area_km2
  FROM read_parquet('s3://public-ca30x30/ecoregion/hex-res9/h0=*/data_0.parquet') e
  JOIN aoi a ON e.h0 = a.h0 AND e.h8 = a.h8
),
prot9 AS (
  SELECT w.h0, w.h9, w.w1 + w.w2 AS pw
  FROM read_parquet('s3://public-ca30x30/conserved-areas-terrestrial-2025/hex-weights-res9/h0=*/data_0.parquet') w
  JOIN aoi a ON w.h0 = a.h0 AND w.h8 = a.h8
),
c AS (
  SELECT l.land_area_km2 AS a, x.whp_class,
         CASE WHEN x.whp_class IN (4, 5) THEN 1 ELSE 0 END AS hi,
         COALESCE(p.pw, 0) AS pw
  FROM land9 l
  JOIN whp x ON l.h0 = x.h0 AND l.h9 = x.h9
  LEFT JOIN prot9 p ON l.h0 = p.h0 AND l.h9 = p.h9
)
SELECT
  SUM(a)                                               AS mapped_land_km2,
  SUM(a * hi) / SUM(a)                                 AS whp_high_share,          -- classes 4-5 of all mapped land (incl. non-burnable)
  SUM(a * hi) / NULLIF(SUM(a) FILTER (WHERE whp_class <= 5), 0) AS whp_high_share_burnable,
  SUM(a * hi * pw)       / NULLIF(SUM(a * pw), 0)       AS whp_high_share_protected,
  SUM(a * hi * (1 - pw)) / NULLIF(SUM(a * (1 - pw)), 0) AS whp_high_share_unprotected
FROM c
```
Columns: mapped_land_km2, whp_high_share (of all land), whp_high_share_burnable (excluding classes 6–7), whp_high_share_protected, whp_high_share_unprotected

| AOI | high/very-high share | of burnable | prot / unprot | runtime |
|---|---|---|---|---|
| Alameda | 25.5% | 44.0% | 27.8% / 25.1% | 6 s |
| Modoc | 28.8% | 33.4% | 12.0% / 29.9% | 4 s |
| Statewide | 30.1% | 39.5% | 22.5% / 32.8% | 7 s |

Caveat: this layer measures hazard, not risk (no exposure of homes). Class breaks are relative to CONUS.

---

## Q8 `climate_tract_climate`: tract map (GEOID, values) for 2024 CA tracts in the AOI
Tracts: `census-2024-tract` hex res10 `s3://public-census/census-2024/tract/hex/h0=*/data_0.parquet` (GEOID, STATEFP, ALAND, AWATER, h8/h9/h10). The query uses tract res-10 cells inside the AOI and keeps tracts with at least 50% of their (ALAND+AWATER) inside the AOI cells, which drops boundary slivers from neighbor counties.

```sql
WITH aoi AS ({{AOI}}),
tr AS (            -- 2024 CA tract res-10 cells inside the AOI
  SELECT t.GEOID, t.h0, t.h8, t.h9, t.h10, (t.ALAND + t.AWATER) / 1e6 AS tract_km2
  FROM read_parquet('s3://public-census/census-2024/tract/hex/h0=*/data_0.parquet') t
  JOIN aoi a ON t.h0 = a.h0 AND t.h8 = a.h8
  WHERE t.STATEFP = '06'
),
base AS (
  SELECT b.h0, b.h8, b.bio5
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/baseline-1981-2010/hex/h0=*/data_0.parquet') b
  JOIN aoi a ON b.h0 = a.h0 AND b.h8 = a.h8
),
fut AS (
  SELECT f.h0, f.h8, f.bio5_median
  FROM read_parquet('s3://public-bioclimate/chelsa-2-1/ssp370-2041-2070/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
),
d8 AS (
  SELECT b.h0, b.h8, f.bio5_median - b.bio5 AS d5
  FROM base b JOIN fut f ON b.h0 = f.h0 AND b.h8 = f.h8
  WHERE NOT isnan(b.bio5) AND NOT isnan(f.bio5_median)
),
fl AS (
  SELECT DISTINCT f.h0, f.h10
  FROM read_parquet('s3://public-hazard/flood-hazard/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  WHERE f.SFHA_TF = 'T'
),
slr AS (
  SELECT DISTINCT s.h0, s.h10
  FROM read_parquet('s3://public-hazard/sea-level-rise/hex/h0=*/data_0.parquet') s
  JOIN aoi a ON s.h0 = a.h0 AND s.h8 = a.h8
  WHERE s.state = 'CA'
),
burn AS (
  SELECT DISTINCT f.h0, f.h10
  FROM read_parquet('s3://public-fire/calfire-2025/firep/hex/h0=*/data_0.parquet') f
  JOIN aoi a ON f.h0 = a.h0 AND f.h8 = a.h8
  WHERE f.YEAR_ BETWEEN 2021 AND 2025
),
whp AS (
  SELECT x.h0, x.h9
  FROM read_parquet('s3://public-fire/whp-2023-classified-conus/hex/h0=*/data_0.parquet') x
  JOIN aoi a ON x.h0 = a.h0 AND x.h8 = a.h8
  WHERE x.whp_class IN (4, 5)
),
c AS (
  SELECT tr.GEOID, tr.tract_km2,
         h3_cell_area(tr.h10, 'km^2') AS a,
         d.d5,
         CASE WHEN fl.h10   IS NULL THEN 0 ELSE 1 END AS f100,
         CASE WHEN slr.h10  IS NULL THEN 0 ELSE 1 END AS s5,
         CASE WHEN burn.h10 IS NULL THEN 0 ELSE 1 END AS b,
         CASE WHEN whp.h9   IS NULL THEN 0 ELSE 1 END AS w
  FROM tr
  LEFT JOIN d8 d ON tr.h0 = d.h0    AND tr.h8 = d.h8
  LEFT JOIN fl   ON tr.h0 = fl.h0   AND tr.h10 = fl.h10
  LEFT JOIN slr  ON tr.h0 = slr.h0  AND tr.h10 = slr.h10
  LEFT JOIN burn ON tr.h0 = burn.h0 AND tr.h10 = burn.h10
  LEFT JOIN whp  ON tr.h0 = whp.h0  AND tr.h9 = whp.h9
)
SELECT GEOID,
       SUM(a * d5) / SUM(a) FILTER (WHERE d5 IS NOT NULL)  AS bio5_increase_c,
       SUM(a * f100) / SUM(a)                               AS fld100_share,
       SUM(a * s5)   / SUM(a)                               AS slr5ft_share,
       SUM(a * b)    / SUM(a)                               AS burned_share_2021_2025,
       SUM(a * w)    / SUM(a)                               AS whp_high_share,
       SUM(a * GREATEST(f100, s5, w)) / SUM(a)              AS any_hazard_share   -- recommended map value
FROM c
GROUP BY GEOID
HAVING SUM(a) >= 0.5 * ANY_VALUE(tract_km2)                -- drop slivers of tracts mostly outside the AOI
ORDER BY GEOID
```
Columns: GEOID, bio5_increase_c, fld100_share, slr5ft_share, burned_share_2021_2025, whp_high_share, any_hazard_share

| AOI | tracts | runtime | notes |
|---|---|---|---|
| Alameda | 382 | 11–17 s | bio5 +1.50…+1.80 (flat); fld100 max 0.95; any_hazard mean 0.14 |
| Modoc | 4 | 12–13 s | any_hazard 0.11–0.42 |
| Statewide | 9,109 | 27–40 s | |

**Recommended map value: `any_hazard_share`.** It is the share of tract area in the FEMA 100-yr floodplain, in NOAA 5 ft SLR inundation, or in High/Very-High WHP (cells are counted once, using a union, not a sum). It is spatially rich in both urban and rural counties. `bio5_increase_c` is nearly constant within a county (for example 1.50–1.80 °C across Alameda), so it makes a poor map. `burned_share_2021_2025` is mostly zero. The extra columns cost nothing and let the app offer a layer toggle. Alameda returns 382 tracts (379 in-county plus a few neighbors that are mostly inside the AOI's boundary h8 cells); filter by GEOID prefix if a strict county list is wanted.

---

## Proposed CLIMATE RISK panel

Headline numbers (AOI vs statewide):
1. **Hottest-month warming by mid-century**: `climate_heat.bio5_increase_c` (SSP3-7.0, 2041–2070). Alameda +1.7 °C, Modoc +3.1 °C, CA +2.4 °C. Subtitle: GCM range lo–hi.
2. **Land in 100-yr floodplain**: `climate_water_hazard.fld100_share`. Alameda 10.4%, Modoc 10.9%, CA 7.2%. Subtitle: 500-yr share; SLR 5 ft share for coastal AOIs (hide when 0).
3. **Land burned 2021–2025**: `climate_fire_summary.burned_ac_unique` and burned_share. Alameda 2,387 ac (0.4%), Modoc 18,746 ac (0.7%), CA 4.66 M ac (4.6%). Subtitle: Rx-treated acres.
   (Alternate or 4th: High/Very-High wildfire hazard share (Q7): 25% / 29% / 30%; or natural habitat climate-exposed (Q6, hot-dry): 0.1% / 44% / 21%.)

Bar charts:
- **A. Fire activity by year**: `climate_fire_by_year`, grouped bars wildfire_ac vs rx_burn_ac, 2021–2025.
- **B. Hazard exposure on protected vs unprotected land**: grouped bars built from the one-row outputs already fetched (no extra query): 100-yr flood (Q1), burned 2021–25 (Q2), High/VH fire hazard (Q7), habitat climate exposure (Q6). For example, Modoc: protected land is much less exposed to fire hazard (12% vs 30%) and climate exposure (26% vs 45%) but more floodplain (27% vs 10%).
- Optional C: `climate_heat_scenarios` (warming by SSP × period), 10–15 s for a county.

Statewide comparison values are fixed. Precompute them once and ship them as constants (statewide runs take 8–41 s):

| metric | CA |
|---|---|
| bio5 increase SSP3-7.0 2041-70 | +2.41 °C (GCM 1.69–4.17); bio1 +2.15 |
| fld100 / fld500 / slr5ft share | 7.25% / 8.44% / 0.69% |
| fld100 protected / unprotected | 4.5% / 8.2% |
| burned 2021-25 unique | 4,655,182 ac (4.59%); prot 4.71% / unprot 4.54% |
| Rx 2021-25 unique | 479,834 ac (0.47%) |
| WHP high/VH | 30.1% (prot 22.5% / unprot 32.8%) |
| habitat exposed hot-dry / warm-wet | 21.2% / 23.7% |

Per-county runtime of the full panel (Q1 + Q2 + Q3 + Q4 + Q7, run in parallel): about 15 s wall clock, bounded by Q1 and Q2 at roughly 10–15 s each when the server is not loaded.
