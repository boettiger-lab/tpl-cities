/**
 * Travel-time isochrones and polygon areas of interest.
 *
 * Isochrones come from a Valhalla routing server (keyless, CORS-enabled; the
 * public FOSSGIS instance by default — swap `routing.url` in config for a
 * self-hosted one). Any polygon (isochrone, drawn, uploaded) becomes an AOI by
 * H3 polyfill on the DuckDB server, so every theme's SQL runs unchanged.
 */

export const MODES = {
    walk: { label: 'Walk', costing: 'pedestrian', icon: '🚶' },
    bike: { label: 'Bike', costing: 'bicycle', icon: '🚲' },
    drive: { label: 'Drive', costing: 'auto', icon: '🚗' },
};

/**
 * Fetch nested isochrones for one origin and mode.
 * Returns [{ minutes, geometry }] sorted by minutes ascending.
 */
export async function fetchIsochrones(routing, { lon, lat }, mode, minutes) {
    const m = MODES[mode];
    if (!m) throw new Error(`Unknown mode ${mode}`);
    const body = {
        locations: [{ lat, lon }],
        costing: m.costing,
        contours: minutes.map(t => ({ time: t })),
        polygons: true,
        denoise: 0.3,
        generalize: 25,   // metres; keeps polygons small without visible loss
    };
    const url = `${routing.url.replace(/\/$/, '')}/isochrone?json=${encodeURIComponent(JSON.stringify(body))}`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`Routing server error ${res.status}`);
    const fc = await res.json();
    if (!fc.features?.length) throw new Error('No isochrone returned for this location');
    return fc.features
        .map(f => ({ minutes: Number(f.properties.contour), geometry: f.geometry }))
        .sort((a, b) => a.minutes - b.minutes);
}

/** GeoJSON Polygon/MultiPolygon → list of WKT POLYGON strings (holes kept). */
export function geometryToWktPolygons(geom) {
    const polys = geom.type === 'Polygon' ? [geom.coordinates]
        : geom.type === 'MultiPolygon' ? geom.coordinates
        : [];
    return polys.map(rings => 'POLYGON(' + rings.map(r =>
        '(' + closeRing(r).map(([x, y]) => `${x.toFixed(6)} ${y.toFixed(6)}`).join(', ') + ')').join(', ') + ')');
}

function closeRing(r) {
    const [a, b] = [r[0], r[r.length - 1]];
    return a[0] === b[0] && a[1] === b[1] ? r : [...r, a];
}

/**
 * Build an AOI from nested bands: [{ minutes, geometry }].
 * The AOI is the band `selected` (minutes); `bands10` labels every cell with
 * the smallest band containing it, for "how does reach grow with time" queries.
 */
export function bandsAoi(bands, selected, label, origin = null) {
    const rows = [];
    for (const b of bands) {
        for (const w of geometryToWktPolygons(b.geometry)) rows.push(`(${Number(b.minutes)}, '${w}')`);
    }
    const cells = `SELECT band, unnest(h3_polygon_wkt_to_cells(wkt, 10)) AS c FROM (VALUES ${rows.join(', ')}) t(band, wkt)`;
    const bands10 = `SELECT MIN(band) AS band, h3_cell_to_parent(c, 0) AS h0, h3_cell_to_parent(c, 8) AS h8, c AS h10 FROM (${cells}) GROUP BY c`;
    const sel = Number(selected);
    const sql10 = `SELECT h0, h8, h10 FROM (${bands10}) WHERE band <= ${sel}`;
    return {
        key: `iso:${label}:${sel}:${hash(rows.join())}`,
        kind: 'isochrone',
        label,
        sql10,
        sql: `SELECT DISTINCT h0, h8 FROM (${sql10})`,
        bands10,
        origin: origin ? { lat: +origin.lat, lon: +origin.lon } : null,
    };
}

/** AOI from arbitrary polygons (drawn / uploaded GeoJSON). */
export function polygonAoi(geometries, label) {
    const ws = geometries.flatMap(geometryToWktPolygons).map(w => `('${w}')`);
    const sql10 = `SELECT DISTINCT h3_cell_to_parent(c, 0) AS h0, h3_cell_to_parent(c, 8) AS h8, c AS h10 FROM (SELECT unnest(h3_polygon_wkt_to_cells(wkt, 10)) AS c FROM (VALUES ${ws.join(', ')}) t(wkt))`;
    return { key: `poly:${hash(ws.join())}`, kind: 'polygon', label, sql10, sql: `SELECT DISTINCT h0, h8 FROM (${sql10})` };
}

function hash(s) {
    let h = 0;
    for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
    return (h >>> 0).toString(36);
}

/** Keyless geocoder (Photon / OSM), restricted to California's bounding box. */
export async function geocode(q, { bbox = [-124.5, 32.5, -114.1, 42.1], limit = 6 } = {}) {
    const url = `https://photon.komoot.io/api/?q=${encodeURIComponent(q)}&limit=${limit}&bbox=${bbox.join(',')}`;
    const res = await fetch(url);
    if (!res.ok) throw new Error(`Geocoder error ${res.status}`);
    const fc = await res.json();
    return fc.features.map(f => {
        const p = f.properties;
        const where = [p.street && p.housenumber ? `${p.housenumber} ${p.street}` : p.street, p.city || p.county].filter(Boolean).join(', ');
        return { name: p.name || where || 'Location', detail: p.name ? where : '', lon: f.geometry.coordinates[0], lat: f.geometry.coordinates[1] };
    });
}
