# California Community Profiles

A map + dashboard that profiles any California **city, county, congressional district, or State Senate / Assembly district** across a configurable set of dimensions: currently **park access**, **health & equity**, **climate risk**, and **biodiversity**. Each profile also has an "at a glance" summary.

There is **no LLM** in the loop. Every number, chart and map layer comes from a fixed, reviewable SQL template. The browser sends the SQL to the public [duckdb-geo MCP server](https://duckdb-mcp.nrp-nautilus.io/mcp), which queries cloud-native H3-indexed GeoParquet. The "Method & SQL" link under each panel shows the exact SQL that ran for the selected place.

Sibling of [tpl-ca](https://github.com/boettiger-lab/tpl-ca), which offers open-ended LLM chat over the same data.

## How it works

```
index.html            static shell (MapLibre + PMTiles from CDN, no build step)
app/                  ES modules
  mcp.js              tiny MCP client: one stateless POST per query; wraps each
                      query in to_json(list(...)) so results come back as one
                      JSON cell (avoids the server's 50-row markdown preview)
  engine.js           loads config, expands SQL templates, caches results
  main.js             UI: jurisdiction → dimensions → place → report; URL hash state
  map.js              boundaries (PMTiles), selection, tract choropleth
  charts.js           horizontal bar charts in plain SVG
config/
  app.json            jurisdictions (AOI SQL, pick list, boundary tiles), theme list
  themes/<id>/        theme.json (headlines, charts, map) + *.sql templates
data/
  lists/*.json        precomputed pick lists (id, name, bbox)
  statewide.json      precomputed statewide results for every theme query
  peers/<theme>/<jur>.json  precomputed per-jurisdiction scores (for ranks)
scripts/precompute.mjs   regenerates data/ using the same engine
```

### SQL template contract

A theme's `.sql` files may use two tokens. Both expand to a `SELECT` over the selected area's H3 cells:

| Token | Columns | Use for |
|---|---|---|
| `{{AOI}}` | `h0, h8` (res 8, ~0.74 km²) | fast landscape metrics (species ranges, fire, flood); overhangs boundaries by up to ~0.5 km |
| `{{AOI10}}` | `h0, h8, h10` (res 10, ~0.015 km²) | population-weighted or boundary-sensitive metrics (people, income, protected share) |

Conventions:
- Start with `WITH aoi AS MATERIALIZED ({{AOI}})`.
- Join on `h0` as well as the cell id.
- Assign tracts and block groups to an area when **most of their cells** fall inside it.
- **Protected** means California 30x30 conserved land, **GAP 1–2**, taken from the 2025 Conserved Areas per-cell weights (`w1 + w2`) with a LEFT JOIN onto the CA ecoregion land grid. This is the same definition as the [ca-30x30](https://github.com/boettiger-lab/ca-30x30) app.

The same template runs for any area. The statewide comparison is simply the template run over all of California.

### Adding a theme

1. Create `config/themes/<id>/` with a `theme.json` and one or more `.sql` files.
2. Add `<id>` to `themes` in `config/app.json`.
3. Run `node scripts/precompute.mjs statewide <id>` to cache the statewide comparison.

`theme.json`:

```jsonc
{
  "label": "…", "color": "#hex", "blurb": "…",
  "queries": { "name": { "file": "name.sql", "statewide": true } },
  "headlines": [ { "query": "name", "field": "col", "label": "…", "format": "pct|int|usd|acres|compact|num1|degC",
                   "row": {"col": "value"},             // optional: pick a row other than the first
                   "detail_field": "col", "detail_template": "{} …", "compare": true } ],
  "charts": [ { "query": "name", "title": "…", "category": "col", "series": [ {"field": "col", "label": "…", "color": "#hex"} ],
                "stacked": true, "format": "…", "compare": {"field": "col"},   // statewide tick per row
                "label_width": 220,                                  // wider category labels (px)
                "statewide_row": true, "exclude": {"col": "value"}, "sort": "desc", "limit": 10,
                "wide": true } ],                                      // span both columns in a wide panel
  "peers": { "file": "peers.sql" },                        // optional: see "Ranks" below
  "map": { "query": "map", "id_field": "GEOID", "value_field": "value", "label": "…", "format": "…",
           "ramp": ["#…", "…"], "breaks": [ … ] }           // breaks optional (default: quantiles)
}
```

The map query returns `(GEOID, value)` for the 2024 census tracts in the area.

A headline can carry `"rank": {"field": "score"}`, which adds "#9 of 58 California counties" to the tile. Ranks come from the theme's `peers.sql`, run once per jurisdiction type by `node scripts/precompute.mjs peers <theme>`. Its `{{CELLS10}}` token expands to the jurisdiction's `cells10` query, `(id, h0, h10)` for every feature, so one query scores them all; it must return `id` plus the ranked field, computed the same way as the live query.

### Park access score

The **Park access** theme (`config/themes/access/`) uses TPL ParkServe's 10-minute-walk service areas. Block-group residents are spread evenly over each block group's res-10 cells and counted as served where a cell is inside any park's walk zone. This matches TPL's published city figures within about 1.5 points. The 0–100 score is the average of **reach** and **room**, multiplied by a **fairness** factor:

- **Reach:** % of residents within a 10-minute walk of any park.
- **Room:** % of residents within a 10-minute walk of a park of 10 acres or more.
- **Fairness:** walk access in lower-income block groups (median household income under $80k) divided by access in the rest, capped at 1. Places where lower-income areas are less served lose points proportionally; places with no access score near 0.

The theme also maps access by tract, lists the tracts with the most unserved residents, and breaks unserved residents down by TPL's park-need priority.

### Adding a jurisdiction type

Add an entry to `jurisdictions` in `config/app.json`. It needs:
- `aoi` and `aoi10` templates, which use `{{ID}}`;
- a `list` query returning `id, name, xmin, ymin, xmax, ymax`;
- `boundary` PMTiles settings;
- optionally, `cells10` (every feature's `id, h0, h10`) and `peer_label`, for ranks.

Then run `node scripts/precompute.mjs lists`. Drawn or uploaded polygons are planned to plug in the same way, with an AOI built from an H3 polyfill.

## Site variants

Each subfolder with an `index.html` is a separate variant served at its own path. Variants share the code in `app/` and keep their own `config/` and `data/`.

| Path | Variant |
|---|---|
| `/` | **Community Profiles**: jurisdiction-based profiles (this README) |
| `/access/` | **Nature Within Reach**: click a point and choose walk, bike or drive and 5/10/15 minutes; summarises the reachable area (isochrone) |

To make a new variant, copy a variant folder, edit its `config/app.json` and themes, and run `node scripts/precompute.mjs --site <folder> statewide`. A theme id in `app.json` can be a path such as `"../config/themes/equity"`, so variants can reuse each other's themes.

### Isochrone AOIs (`/access/`)

- Travel-time polygons come from a [Valhalla](https://github.com/valhalla/valhalla) router: the public FOSSGIS server by default, set in `routing.url`.
- `app/iso.js` turns the polygons into SQL. The DuckDB server fills them with res-10 H3 cells (`h3_polygon_wkt_to_cells`), so every theme's SQL runs unchanged on an isochrone. Drawn or uploaded polygons can use the same path (`polygonAoi`).
- Isochrone AOIs add these tokens:
  - `{{BANDS10}}`: every cell labelled with the smallest 5/10/15-minute band that reaches it, for "reach grows with time" charts.
  - `{{ORIGIN_LAT}}` and `{{ORIGIN_LON}}`: the starting point.
- A theme's `map.type: "hex"` draws res-9 hexagons from H3 id strings (`h3_h3_to_string`) instead of census tracts.

See `notes/isochrones.md` for the routing options (on the fly vs precomputed, and transit).

## Run locally

```sh
python3 -m http.server 8000      # then open http://localhost:8000
node scripts/precompute.mjs      # refresh data/ (Node ≥ 18)
```

## Deploy

Served by GitHub Pages from `main` (repo root): https://boettiger-lab.github.io/tpl-cities/. Every push to `main` redeploys. The site is fully static: there is no LLM, no secrets and no proxy, and the browser calls the public MCP endpoint in `config/app.json` directly. To point it elsewhere, edit `mcp_url` or serve a `config.json` with `mcp_server_url`.
