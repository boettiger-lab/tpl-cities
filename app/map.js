/**
 * Map: basemap, jurisdiction boundaries (PMTiles), selected outline, and a
 * tract choropleth driven by query results (GEOID → value).
 */

import { fmt, escapeHtml } from './format.js';
import { hover } from './charts.js';

const BASE_STYLE = {
    version: 8,
    glyphs: 'https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf',
    sources: {
        base: {
            type: 'raster', tileSize: 256, maxzoom: 16,
            tiles: ['https://services.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Light_Gray_Base/MapServer/tile/{z}/{y}/{x}'],
            attribution: 'Tiles &copy; Esri &mdash; Esri, HERE, Garmin, &copy; OpenStreetMap contributors',
        },
        ref: {
            type: 'raster', tileSize: 256, maxzoom: 16,
            tiles: ['https://services.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Light_Gray_Reference/MapServer/tile/{z}/{y}/{x}'],
        },
    },
    layers: [
        { id: 'base', type: 'raster', source: 'base' },
        // data layers are inserted below 'ref' so place labels stay on top
        { id: 'ref', type: 'raster', source: 'ref' },
    ],
};

export class MapView {
    constructor(containerId, app) {
        this.app = app;
        const protocol = new pmtiles.Protocol();
        maplibregl.addProtocol('pmtiles', protocol.tile);
        this.map = new maplibregl.Map({
            container: containerId,
            style: BASE_STYLE,
            center: app.view.center,
            zoom: app.view.zoom,
            attributionControl: { compact: true },
        });
        this.map.addControl(new maplibregl.NavigationControl({ showCompass: false }), 'top-right');
        this.ready = new Promise(r => this.map.on('load', r));
        this.jur = null;
        this.onPick = () => {};
        this._hoverId = null;
        this._popup = new maplibregl.Popup({ closeButton: false, closeOnClick: false, offset: 8 });
        this._choro = null;
    }

    async showJurisdiction(jur) {
        await this.ready;
        const m = this.map;
        for (const id of ['jur-fill', 'jur-line', 'jur-hover', 'jur-selected']) if (m.getLayer(id)) m.removeLayer(id);
        if (m.getSource('jur')) m.removeSource('jur');
        this.jur = jur;
        const b = jur.boundary;
        m.addSource('jur', { type: 'vector', url: `pmtiles://${b.url}`, promoteId: b.id_prop });
        const filter = b.filter || true;
        m.addLayer({
            id: 'jur-fill', type: 'fill', source: 'jur', 'source-layer': b.source_layer, filter,
            paint: {
                'fill-color': '#006837',
                'fill-opacity': ['case', ['boolean', ['feature-state', 'hover'], false], 0.12, 0.02],
            },
        }, 'ref');
        m.addLayer({
            id: 'jur-line', type: 'line', source: 'jur', 'source-layer': b.source_layer, filter,
            paint: { 'line-color': '#2f4a2c', 'line-opacity': 0.55, 'line-width': ['interpolate', ['linear'], ['zoom'], 5, 0.4, 10, 1.2] },
        }, 'ref');
        m.addLayer({
            id: 'jur-selected', type: 'line', source: 'jur', 'source-layer': b.source_layer,
            filter: ['==', ['get', b.id_prop], '__none__'],
            paint: { 'line-color': '#111', 'line-width': 2.5 },
        });
        this._wire();
    }

    _wire() {
        if (this._wired) return;
        this._wired = true;
        const m = this.map;
        m.on('mousemove', 'jur-fill', e => {
            const f = e.features[0];
            if (!f) return;
            m.getCanvas().style.cursor = 'pointer';
            if (this._hoverId !== null && this._hoverId !== f.id) {
                m.setFeatureState({ source: 'jur', sourceLayer: this.jur.boundary.source_layer, id: this._hoverId }, { hover: false });
            }
            this._hoverId = f.id;
            m.setFeatureState({ source: 'jur', sourceLayer: this.jur.boundary.source_layer, id: f.id }, { hover: true });
            const name = f.properties[this.jur.boundary.name_prop] ?? f.id;
            let html = `<b>${escapeHtml(name)}</b>`;
            const t = this._tractAt(e.point);
            if (t) html += `<br>${escapeHtml(this._choro.label)}: ${fmt(t.value, this._choro.format)}`;
            this._popup.setLngLat(e.lngLat).setHTML(html).addTo(m);
        });
        m.on('mouseleave', 'jur-fill', () => {
            m.getCanvas().style.cursor = '';
            if (this._hoverId !== null) {
                m.setFeatureState({ source: 'jur', sourceLayer: this.jur.boundary.source_layer, id: this._hoverId }, { hover: false });
            }
            this._hoverId = null;
            this._popup.remove();
        });
        m.on('click', 'jur-fill', e => {
            const f = e.features[0];
            if (f) this.onPick(String(f.properties[this.jur.boundary.id_prop] ?? f.id));
        });
    }

    _tractAt(point) {
        if (!this._choro || !this.map.getLayer('tract-fill')) return null;
        const f = this.map.queryRenderedFeatures(point, { layers: ['tract-fill'] })[0];
        if (!f) return null;
        const id = String(f.properties[this.app.tracts.id_prop]);
        return this._choro.values.has(id) ? { id, value: this._choro.values.get(id) } : null;
    }

    async select(id, bbox) {
        await this.ready;
        const b = this.jur.boundary;
        this.map.setFilter('jur-selected', ['==', ['to-string', ['get', b.id_prop]], String(id)]);
        if (bbox && bbox.every(Number.isFinite)) {
            const narrow = window.matchMedia('(max-width: 820px)').matches;
            this.map.fitBounds([[bbox[0], bbox[1]], [bbox[2], bbox[3]]], { padding: narrow ? 20 : 50, duration: 800 });
        }
    }

    clearSelection() {
        if (this.map.getLayer('jur-selected')) this.map.setFilter('jur-selected', ['==', ['get', this.jur.boundary.id_prop], '__none__']);
        this.clearChoropleth();
    }

    /**
     * rows: [{ [idField]: GEOID, [valueField]: number }]
     * spec: theme.map  { id_field, value_field, label, format, ramp, breaks? }
     */
    async setChoropleth(spec, rows) {
        await this.ready;
        const m = this.map;
        const t = this.app.tracts;
        if (!m.getSource('tracts')) {
            m.addSource('tracts', { type: 'vector', url: `pmtiles://${t.url}` });
        }
        for (const id of ['tract-fill', 'tract-line']) if (m.getLayer(id)) m.removeLayer(id);

        const values = new Map();
        for (const r of rows) {
            const v = Number(r[spec.value_field]);
            if (Number.isFinite(v)) values.set(String(r[spec.id_field]), v);
        }
        if (!values.size) { this.clearChoropleth(); return null; }
        const breaks = spec.breaks || quantileBreaks([...values.values()], spec.ramp.length);
        const colorOf = v => spec.ramp[Math.min(spec.ramp.length - 1, breaks.filter(b => v >= b).length)];

        const match = ['match', ['to-string', ['get', t.id_prop]]];
        for (const [id, v] of values) match.push(id, colorOf(v));
        match.push('rgba(0,0,0,0)');

        m.addLayer({
            id: 'tract-fill', type: 'fill', source: 'tracts', 'source-layer': t.source_layer,
            filter: ['in', ['to-string', ['get', t.id_prop]], ['literal', [...values.keys()]]],
            paint: { 'fill-color': match, 'fill-opacity': 0.78 },
        }, 'jur-fill');
        m.addLayer({
            id: 'tract-line', type: 'line', source: 'tracts', 'source-layer': t.source_layer,
            filter: ['in', ['to-string', ['get', t.id_prop]], ['literal', [...values.keys()]]],
            paint: { 'line-color': '#fff', 'line-width': 0.4, 'line-opacity': 0.8 },
        }, 'jur-fill');
        this._choro = { ...spec, values };
        return { breaks, ramp: spec.ramp, n: values.size };
    }

    clearChoropleth() {
        for (const id of ['tract-fill', 'tract-line']) if (this.map.getLayer(id)) this.map.removeLayer(id);
        this._choro = null;
    }
}

/** Interior quantile cut points (ramp.length − 1 of them), deduplicated. */
function quantileBreaks(vals, k) {
    const s = [...vals].sort((a, b) => a - b);
    const out = [];
    for (let i = 1; i < k; i++) {
        const q = s[Math.min(s.length - 1, Math.floor((i / k) * s.length))];
        if (!out.length || q > out[out.length - 1]) out.push(q);
    }
    return out;
}

export function renderLegend(el, spec, info) {
    if (!info) { el.hidden = true; return; }
    const { breaks, ramp } = info;
    const used = ramp.slice(0, breaks.length + 1);
    el.innerHTML = `
        <div class="title">${escapeHtml(spec.label)}</div>
        <div class="ramp">${used.map(c => `<span style="background:${c}"></span>`).join('')}</div>
        <div class="ends"><span>${breaks.length ? '< ' + fmt(breaks[0], spec.format) : ''}</span><span>${breaks.length ? '≥ ' + fmt(breaks[breaks.length - 1], spec.format) : ''}</span></div>
        <div class="tile-note">${escapeHtml(spec.note || 'Census tracts, quantile classes within this area')}</div>`;
    el.hidden = false;
    // per-class hover readout
    el.querySelectorAll('.ramp span').forEach((s, i) => {
        const a = i === 0 ? null : breaks[i - 1];
        const b = i < breaks.length ? breaks[i] : null;
        const txt = a === null ? `< ${fmt(b, spec.format)}` : b === null ? `≥ ${fmt(a, spec.format)}` : `${fmt(a, spec.format)} – ${fmt(b, spec.format)}`;
        hover(s, txt);
    });
}
