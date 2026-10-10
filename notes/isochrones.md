# Isochrones: on the fly or pre-ingested?

This note covers how the `/access/` variant gets travel-time areas, and the options for doing it better.

The reference app is SF Biodiversity Access (an R Shiny app on Hugging Face, `diegoellissoto/Biodiversity_Access`):
- Walk, bike and drive isochrones come live from the Mapbox Isochrone API, which needs a token.
- Transit comes from `gtfsrouter` on the Muni GTFS feed.
- Percentiles come from a precomputed reference: 24k SF 100 m grid origins × {walk, bike, drive} × {5, 10, 15} min, all built with Mapbox.

## Walk / bike / drive: on the fly is the right call

- **Cost:** one routing call returns all three contours in under a second. Filling the polygon with H3 cells on the DuckDB server takes about 0.2 s. The theme queries then run as for any other area: 4–15 s for a 15-minute walk, about 17 s for a 15-minute drive in central LA (479 km²).
- **Why not precompute:** statewide it would mean about 3.6M res-9 origins × 3 modes × 3 times. That is wasteful compared with live routing.
- **Router:** the public FOSSGIS Valhalla (`valhalla1.openstreetmap.de`) is keyless and allows browser requests, but it is shared with a fair-use policy.
- **For real use, self-host Valhalla on NRP** (one container, built from the Geofabrik California OSM extract) and change `routing.url`.
  - The Valhalla image is `ghcr.io/valhalla/valhalla-scripted`; California tiles are a few GB.
  - No app changes are needed.
  - OSRM or OpenRouteService would also work behind the same `fetchIsochrones` interface.

## Transit: pre-ingest

- **Why it's harder:** transit reachability depends on timetables, departure time and transfers. Valhalla's multimodal mode exists but is limited, and doing GTFS routing in the browser is heavy.
- **Suggested pipeline:**
  1. Ingest the Cal-ITP statewide GTFS (all California agencies).
  2. Run r5py (R5) or OpenTripPlanner for a fixed departure window, e.g. weekday 8–9am, taking the median over departure minutes.
  3. Compute travel-time matrices from res-9 origins (populated cells only, roughly 300k) to res-9 destinations, capped at 15 or 30 minutes.
  4. Store `(origin_h9, dest_h9, minutes)` as H3-partitioned parquet in the STAC catalog.
- **Then a transit isochrone is just a query:**
  `SELECT dest_h9 FROM tt WHERE origin_h9 = h3_latlng_to_cell(lat, lon, 9) AND minutes <= 15`.
- **Effort:** this is a moderate batch job, a few CPU-hours per metro region. It also covers "walk + transit", since R5 includes the walk legs.

## Percentiles / a composite index

- **What Diego did:** his BAI is scored against a citywide reference distribution of isochrones.
- **The same here:** sample a few hundred to a few thousand origins per mode × time across California, run the access themes, and store the distributions in `access/data/reference.json`. The app could then report "more species within a 15-minute walk than 72% of California neighbourhoods".
- **How to sample:** weight by population so the percentiles mean "typical resident". Separate distributions by urban/rural context are optional.

## Data gaps vs the Shiny app

| Shiny metric | Here | Status |
|---|---|---|
| GBIF species/records | `gbif-derived` 2026-06, res-10 | ✓ (quality-filtered; eBird dominates record counts) |
| % greenspace (OSM) | TPL ParkServe open-access parks | ✓ (CPAD Open Access is a public-license alternative) |
| Distance to nearest greenspace | ParkServe, H3 grid disk around the origin | ✓ |
| NDVI (Sentinel-2) | — | ✗ not in catalog; LANDFIRE canopy is a stand-in that misses street trees |
| Transit stops/routes | — | ✗ needs GTFS ingest (see above) |
| CalEnviroScreen, income, population | CES 5.0, ACS 2020–24, DWR DAC | ✓ (apportioned by area, which fixes the Shiny app's population bug) |
| SF EJ communities, RSF projects | — | SF-only layers; could be added for an SF-focused variant |
