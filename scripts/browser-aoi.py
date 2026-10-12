#!/usr/bin/env python3
"""
Area files for the in-browser variant: each jurisdiction feature's H3 cells,
compacted, as wasm/data/aoi/<jur>.parquet (res 10, the cells of app.json's
"aoi10") and <jur>-r8.parquet (res 8, the cells of "aoi"). Columns: id, cell.
The wasm config's AOI templates uncompact them with h3_uncompact_cells.

    python3 scripts/browser-aoi.py [jurisdiction ...]

Run scripts/browser-tiles.py afterwards to refresh <jur>-counties.json.
"""

import duckdb, os, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = f'{ROOT}/wasm/data/aoi'
SC = 's3://us-west-2.opendata.source.coop/cboettig/census'   # source.coop mirror of public-census

# (res-10 cells, res-8 cells) per feature, matching config/app.json
SRC = {
    'county': (f"SELECT left(GEOID, 5) AS id, h10 AS c FROM read_parquet('{SC}/census-2024/tract/hex/h0=*/data_0.parquet') WHERE STATEFP = '06'",
               f"SELECT GEOID AS id, h8 AS c FROM read_parquet('{SC}/census-2024/county/hex/h0=*/data_0.parquet') WHERE STATEFP = '06'"),
    'city': (f"SELECT GEOID AS id, h10 AS c FROM read_parquet('{SC}/census-2024/place/hex/h0=*/data_0.parquet') WHERE STATEFP = '06' AND CLASSFP LIKE 'C%'",
             f"SELECT GEOID AS id, h8 AS c FROM read_parquet('{SC}/census-2024/place/hex/h0=*/data_0.parquet') WHERE STATEFP = '06' AND CLASSFP LIKE 'C%'"),
}
for jur, year in (('cd', 2024), ('sldu', 2025), ('sldl', 2025)):
    SRC[jur] = tuple(f"SELECT GEOID AS id, {h} AS c FROM read_parquet('{SC}/census-{year}/{jur}/hex/h0=*/data_0.parquet') WHERE STATEFP = '06'"
                     for h in ('h10', 'h8'))

con = duckdb.connect()
con.execute("SET threads = 2; SET memory_limit = '8GB'; INSTALL h3 FROM community; LOAD h3; INSTALL httpfs; LOAD httpfs;")
con.execute("CREATE SECRET sc (TYPE s3, REGION 'us-west-2', URL_STYLE 'path', SCOPE 's3://us-west-2.opendata.source.coop');")
os.makedirs(OUT, exist_ok=True)
for jur in sys.argv[1:] or SRC:
    for q, suffix in zip(SRC[jur], ('', '-r8')):
        t = time.time()
        f = f'{OUT}/{jur}{suffix}.parquet'
        con.execute(f"""COPY (
            SELECT id, unnest(h3_compact_cells(list(DISTINCT c))) AS cell FROM ({q}) GROUP BY id ORDER BY id, cell
          ) TO '{f}' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE 8192)""")
        print(f'{jur}{suffix}: {os.path.getsize(f) / 1e6:.2f} MB, {time.time() - t:.0f}s', flush=True)
