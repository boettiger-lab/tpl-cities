# Dropping the MCP server: DuckDB-wasm in the browser

This note covers whether the main app can run its SQL in the visitor's browser instead of on the duckdb-geo MCP server, and what that takes. The prototype is the `/wasm/` variant.

## What works out of the box

- **DuckDB-wasm runs the SQL unchanged.** `@duckdb/duckdb-wasm` 1.33 (DuckDB 1.5.4) loads the `h3` community extension, `httpfs` and `spatial`, and reads `s3://` paths and globs with an anonymous S3 secret per endpoint.
- **CORS allows it.** NRP Ceph (`s3-west.nrp-nautilus.io`) and source.coop (`s3.us-west-2.amazonaws.com/us-west-2.opendata.source.coop`, path-style because the bucket name has dots) both allow cross-origin range reads, HEAD and bucket listing.
- **Mirror coverage.** source.coop mirrors census, CalEnviroScreen, DWR DAC, CAL FIRE, hazard and USFWS under `cboettig/<bucket without "public-">/…`. It does not have ca30x30, TPL, parks, SWAP or CHELSA.
- **One workaround.** Some GeoParquet metadata makes the wasm build fail with `stoi: no conversion`, from NRP and source.coop alike (the same family as boettiger-lab/datasets#106). The app never reads geometry from parquet, so the client turns GeoParquet conversion off.

## Why reading the public layout directly is too slow

The public hex datasets are national. Each res-0 (`h0`) partition holds up to about 100 million rows, ordered by feature id rather than by location. So a query for one county reads most of a partition's `h10` column, and the wasm build reads it with one synchronous range request at a time.

Alameda County, all 21 queries:

| Setup | Time | Downloaded | Requests |
|---|---|---|---|
| Native DuckDB, NRP | 1–80 s per query | ~5.5 GB | ~38,000 |
| Browser, NRP | one query ran out of memory at 3.1 GB | | |
| Browser, source.coop + NRP, 3 workers | 11.5 min | 2.8 GB | 17,000 |

The results were correct, but this is too slow for an app.

**Sorting does not fix it.** California-only, h3-sorted copies cut the bytes for the Park access queries about fourfold. But with 40 ms of latency per request they took just as long (107 s), because the sequential request count (about 2,600) is the bottleneck, not the bytes.

## The browser tile set

`scripts/browser-tiles.py` writes California-only copies of each dataset the themes read:
- one small parquet file per county, with only the columns the SQL mentions;
- rows of block groups and tracts go whole to their county's file, so per-feature totals stay right;
- other rows go to the county of their res-8 cell;
- datasets under 3 MB, and WCB projects (which cross county lines and are totalled whole), go into one statewide file.

The client:
1. looks up the place's counties (`wasm/data/aoi/<jur>-counties.json`, which includes neighbours touched by the place's res-10 and res-8 cells);
2. fetches those files in parallel with `fetch()`;
3. registers them with DuckDB as buffers;
4. points the query's glob at them.

The whole tile set is about 650 MB (1,396 files; TPL ParkServe is excluded because its terms don't allow redistribution, so the app reads it from NRP; the Park access headline scores are precomputed per jurisdiction instead, in `data/results/access/access/`, since aggregate statistics were cleared for publication on 2026-10-13, while tract shares and park-need priority still read ParkServe live), published on source.coop at `s3://us-west-2.opendata.source.coop/cboettig/tpl-cities/browser-tiles/` (read over the direct S3 URL; the `data.source.coop` gateway serves only registered products). Benchmarks are full profiles, all 21 queries, with 40 ms simulated latency per request:

| Place | Time | Files | Downloaded |
|---|---|---|---|
| Oakland | 2.1 s | 108 | 22 MB |
| Alameda County | 3.5 s | 186 | 42 MB |
| Los Angeles County | 11 s | 134 | 155 MB |

- **Cold page load from the hosted tiles.** In headless Chromium, the whole profile finished, from a cold page load and including starting DuckDB, in: Oakland 9.5 s, California's 12th congressional district 8.8 s, Alameda County 13 s, Los Angeles County 16 s.
- **Bandwidth.** Download size, not latency, now sets the time: about 155 MB for Los Angeles takes about 25 s at 50 Mbit/s. Finer tiles (tract or res-5 cells instead of counties, or no neighbouring counties for the res-10-only datasets) would cut this.

**Results match the server.** All 63 query results (21 queries for Alameda, Los Angeles and Oakland) match the MCP server: the same rows, and numbers equal to within 4 × 10⁻¹¹.

The comparison also turned up a bug in the main app. `access/tracts.sql` labelled each tract from an arbitrary block group's latitude and an arbitrary one's longitude (`any_value` twice), so labels could change between runs. It now uses the first block group's interior point.

## Keeping it current

**Status (2026-10-13): manual, pending a more general solution.** The tile set at `cboettig/tpl-cities/browser-tiles/` was uploaded by hand. It sits outside the source.coop mirror's managed scope (geo-agent-ops), so nothing rebuilds it when the source data or the theme SQL changes. Whether derived copies like this should move into the managed pipeline, or be rebuilt some other way, is still under discussion. Until then, rebuild by hand when any of these change:
- a dataset the themes read;
- the columns a theme's SQL uses;
- the census boundaries behind the pick lists.

The steps, in order:

1. **Area files** (only if boundaries changed): `python3 scripts/browser-aoi.py` rewrites `wasm/data/aoi/<jur>(-r8).parquet`.
2. **Tiles:** `python3 scripts/browser-tiles.py <dir> [dataset ...]` writes the tiles and `manifest.json`, and refreshes `wasm/data/aoi/<jur>-counties.json`. It never tiles TPL ParkServe (see below).
3. **Upload:**
   ```
   rclone copy <dir> source:us-west-2.opendata.source.coop/cboettig/tpl-cities/browser-tiles/ --exclude _build.duckdb
   ```
   Then check that `manifest.json` lists no `public-tpl` path.
4. **Precomputed results:** `node scripts/precompute.mjs statewide`, `peers` and `results`. These still run through the MCP server.
5. **Commit and deploy:** commit the changed files under `wasm/data/aoi/` and `data/`, then merge so Pages redeploys.

**Redistribution rules** (geo-agent-ops `scripts/check-source-scope.py`; `DATA_WORKFLOWS_HARDENING.md`, 2026-10-12/13):
- TPL ParkServe is host-only. Never tile or upload it, nor its geometry or H3 derivatives.
- Per-jurisdiction aggregates are approved (`data/results/access/access/`, `data/peers/access/`).
- Tract-level shares and the park-need priority breakdown are not approved until TPL answers, so `tracts.sql` and `need.sql` stay live queries.
- SWAP, ca30x30 and WCB are cleared for public use.

## Open items

- **Tile upkeep:** a general solution for derived copies like the tile set (see above). Pending discussion.
- **TPL guidance:** whether tract-level served percentages and the park-need priority breakdown may be published. If yes, add `"precompute"` files for `tracts.sql` and `need.sql`; `/wasm/` then reads no ParkServe at all. These two queries are the remaining ParkServe reads, about 145 requests per profile.
- **WCB is moving to `public-cdfw`.** When it does, update the path in the theme SQL and rebuild that dataset's tile in the same change, or WCB queries in `/wasm/` will fail.
- **Profiling:** profiles take about 16 s after the ParkServe precompute. Per-query timing would show whether anything else is worth precomputing.
- **Area files stay on GitHub Pages** (`wasm/data/aoi`, about 2.4 MB). They are the app's own small files, and serving them from the same origin avoids CORS. Move them to source.coop only if all parquet should live there.

## Trade-offs vs the MCP server

- **Gains:**
  - No server to run or keep up; it survives an NRP outage if the tile set is hosted elsewhere (e.g. source.coop).
  - Visitors' browsers do the work, so traffic doesn't load a shared server.
- **Costs:**
  - The tile set is a derived copy that has to be rebuilt when the data or the SQL's columns change (`python3 scripts/browser-tiles.py <dir>`, then upload).
  - First load pulls about 35 MB of DuckDB wasm and extensions (cached afterwards).
  - Large areas download tens to hundreds of MB.
  - Statewide numbers and peer ranks are still precomputed with the MCP server (`scripts/precompute.mjs`). This could move to native DuckDB.
- **Arbitrary areas:** isochrones or drawn polygons span counties unpredictably, but can use the same tiles if the client computes their counties from their cells.
