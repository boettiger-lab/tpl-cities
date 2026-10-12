#!/usr/bin/env python3
"""
Build the browser data layout for the in-browser (DuckDB-wasm) variant.

The public hex datasets are national and ordered by feature, so a browser
reading them directly makes hundreds of small sequential range requests per
query. This writes California-only copies split into one small file per
county, keeping only the columns the app's SQL uses, so the browser can fetch
the few files a place needs in parallel and query them from memory:

    <out>/<dataset path>/<county fips>.parquet
    <out>/manifest.json      {"datasets": {path: [fips, ...]}, ...}
    wasm/data/aoi/<jur>-counties.json   {feature id: [fips, ...]}

Rows of census-type features (block groups, tracts) go to their own county's
file, whole, so per-feature totals stay right; other rows go to the county of
their res-8 cell. Small datasets, and ones whose features cross county lines
and are totalled whole (WCB projects), are written as one statewide file
"CA". A place's counties are those of its cells (res 10 and res 8) plus those
of any tract touching them.

    python3 scripts/browser-tiles.py <out dir> [dataset ...]
"""

import duckdb, glob, json, os, re, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = sys.argv[1]
ONLY = sys.argv[2:]
MIRRORED = ('census', 'calenviroscreen', 'ca-dac', 'fire', 'hazard', 'usfws')   # on source.coop

con = duckdb.connect(os.path.join(OUT, '_build.duckdb'))
con.execute("SET threads = 2; SET memory_limit = '6GB'; SET preserve_insertion_order = false;")
con.execute("INSTALL httpfs; LOAD httpfs; INSTALL h3 FROM community; LOAD h3;")
con.execute("CREATE OR REPLACE SECRET nrp (TYPE s3, ENDPOINT 's3-west.nrp-nautilus.io', URL_STYLE 'path', REGION '', SCOPE 's3://public-');")
con.execute("CREATE OR REPLACE SECRET sc (TYPE s3, REGION 'us-west-2', URL_STYLE 'path', SCOPE 's3://us-west-2.opendata.source.coop');")


def src(path):
    """Read from the source.coop mirror where it has the dataset (much faster egress)."""
    bucket, rest = path[5:].split('/', 1)
    name = bucket.removeprefix('public-')
    return f"s3://us-west-2.opendata.source.coop/cboettig/{name}/{rest}" if name in MIRRORED else path


# Hex datasets the themes read, and every identifier their SQL mentions.
sql = ''.join(open(f).read() for f in glob.glob(f'{ROOT}/config/themes/*/*.sql'))
words = set(re.findall(r'\w+', sql))
datasets = sorted(set(re.findall(r"read_parquet\('(s3://[^']+?)/h0=\*/data_0\.parquet'\)", sql)))
datasets = [d for d in datasets if not ONLY or any(o in d for o in ONLY)]
# Never redistributed: TPL ParkServe is proprietary ("host, don't redistribute",
# geo-agent-ops redistribution policy / data-workflows#461). The app reads it from NRP.
NO_REDISTRIBUTION = ('public-tpl/parkserve-2025/',)
datasets = [d for d in datasets if not any(x in d for x in NO_REDISTRIBUTION)]

# California res-8 cells → one county each, and res-10 cell → tract county (for place → counties).
if not con.execute("SELECT count(*) FROM duckdb_tables() WHERE table_name = 'h8county'").fetchone()[0]:
    t = time.time()
    con.execute(f"""CREATE TABLE h8county AS
        SELECT h8, min(GEOID) AS county FROM read_parquet('{src('s3://public-census/census-2024/county/hex')}/h0=*/data_0.parquet')
        WHERE STATEFP = '06' GROUP BY h8""")
    con.execute(f"""CREATE TABLE tractcells AS
        SELECT DISTINCT h10, left(GEOID, 5) AS county FROM read_parquet('{src('s3://public-census/census-2024/tract/hex')}/h0=*/data_0.parquet')
        WHERE STATEFP = '06'""")
    print(f'cell → county maps: {time.time() - t:.0f}s', flush=True)

CA_H0 = [r[0] for r in con.execute("SELECT DISTINCT h3_cell_to_parent(h8, 0) FROM h8county").fetchall()]

# Written whole, as one statewide file "CA": datasets whose queries total a
# feature over all its cells (WCB projects cross county lines), and tiny ones.
WHOLE = ('wcb-approved-projects',)
WHOLE_MB = 3

# feature id column whose first 5 digits are the county FIPS
FEATURE = {'GEOID': "left(GEOID, 5)", 'GEOID20': "left(GEOID20, 5)", 'tract': "left(lpad(CAST(CAST(tract AS BIGINT) AS VARCHAR), 11, '0'), 5)"}

manifest_file = os.path.join(OUT, 'manifest.json')
manifest = json.load(open(manifest_file)) if os.path.exists(manifest_file) else {'datasets': {}}
for path in datasets:
    t = time.time()
    rel = path[5:]
    # only California's res-0 partitions
    files = [r[0] for r in con.execute(f"SELECT file FROM glob('{src(path)}/h0=*/data_0.parquet')").fetchall()]
    parts = [f for f in files if any(f'h0={h}/' in f for h in CA_H0)]
    cols = [r[0] for r in con.execute(f"DESCRIBE SELECT * FROM read_parquet({parts}, hive_partitioning = false)").fetchall()]
    keep = [c for c in cols if c in words or c in ('h0', 'h8', 'h9', 'h10')]
    fcol = next((c for c in FEATURE if c in cols), None)
    if fcol:   # only tract / block-group ids nest in counties (place and district ids don't)
        n = con.execute(f"SELECT min(length(CAST({fcol} AS VARCHAR))) FROM (SELECT {fcol} FROM read_parquet({parts}, hive_partitioning = false) LIMIT 1000)").fetchone()[0]
        fcol = fcol if n >= 10 else None
    sel = ', '.join(f'd."{c}"' for c in keep)
    if 'h0' not in keep:   # some datasets carry h0 only in their partition folder names
        sel += ', h3_cell_to_parent(d.h8, 0) AS h0'
    if fcol:
        county = FEATURE[fcol].replace(fcol, f'd."{fcol}"')
        q = f"SELECT {sel}, {county} AS __county FROM read_parquet({parts}, hive_partitioning = false) d WHERE {county} LIKE '06%'"
    else:
        q = f"SELECT {sel}, m.county AS __county FROM read_parquet({parts}, hive_partitioning = false) d JOIN h8county m ON d.h8 = m.h8"
    con.execute(f"CREATE OR REPLACE TEMP TABLE ds AS {q}")
    order = 'h10' if 'h10' in keep else 'h8'
    counties = [r[0] for r in con.execute("SELECT DISTINCT __county FROM ds ORDER BY 1").fetchall()]
    os.makedirs(f'{OUT}/{rel}', exist_ok=True)
    for c in counties:
        con.execute(f"""COPY (SELECT * EXCLUDE (__county) FROM ds WHERE __county = '{c}' ORDER BY {order})
            TO '{OUT}/{rel}/{c}.parquet' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE 122880)""")
    if any(w in rel for w in WHOLE) or sum(os.path.getsize(f'{OUT}/{rel}/{c}.parquet') for c in counties) < WHOLE_MB * 1e6:
        for c in counties:
            os.remove(f'{OUT}/{rel}/{c}.parquet')
        con.execute(f"COPY (SELECT * EXCLUDE (__county) FROM ds ORDER BY {order}) TO '{OUT}/{rel}/CA.parquet' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE 122880)")
        counties = ['CA']
    size = sum(os.path.getsize(f'{OUT}/{rel}/{c}.parquet') for c in counties)
    manifest['datasets'][rel] = counties
    json.dump(manifest, open(manifest_file, 'w'), indent=1)
    print(f'{rel}: {len(counties)} counties, {len(keep)}/{len(cols)} columns, {size / 1e6:.0f} MB, {time.time() - t:.0f}s', flush=True)

# each jurisdiction feature → the county files it needs
aoi_dir = f'{ROOT}/wasm/data/aoi'
for f in sorted(glob.glob(f'{aoi_dir}/*.parquet')):
    jur = os.path.basename(f)[:-8]
    if jur.endswith('-r8'):
        continue
    rows = con.execute(f"""
        WITH cells AS (SELECT id, unnest(h3_uncompact_cells(list(cell), 10)) AS h10 FROM read_parquet('{f}') GROUP BY id),
        cells8 AS (SELECT id, unnest(h3_uncompact_cells(list(cell), 8)) AS h8 FROM read_parquet('{f[:-8]}-r8.parquet') GROUP BY id),
        tract8 AS (SELECT DISTINCT h3_cell_to_parent(h10, 8) AS h8, county FROM tractcells)
        SELECT id, list(DISTINCT county ORDER BY county) FROM (
            SELECT c.id, t.county FROM cells c JOIN tractcells t USING (h10)
            UNION SELECT c.id, m.county FROM cells c JOIN h8county m ON m.h8 = h3_cell_to_parent(c.h10, 8)
            UNION SELECT c.id, t.county FROM cells8 c JOIN tract8 t USING (h8)   -- res-8 area cells overhang the res-10 ones
            UNION SELECT c.id, m.county FROM cells8 c JOIN h8county m USING (h8)
        ) GROUP BY id ORDER BY id""").fetchall()
    json.dump({i: cs for i, cs in rows}, open(f'{aoi_dir}/{jur}-counties.json', 'w'), separators=(',', ':'))
    print(f'{jur}: county lists for {len(rows)} features', flush=True)
