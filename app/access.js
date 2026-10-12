/**
 * "Nature within reach" variant: origin point → travel mode → time budget →
 * isochrone AOI → the same declarative theme cards as the main site.
 *
 * URL hash: #@lat,lon?mode=walk&t=15&themes=a,b&map=a
 */

import { loadConfig, Engine } from './engine.js';
import { MapView, renderLegend } from './map.js';
import { renderThemeCard, shortErr } from './report.js';
import { wireExportButton } from './export.js';
import { MODES, fetchIsochrones, bandsAoi, geocode } from './iso.js';
import { escapeHtml } from './format.js';

const $ = sel => document.querySelector(sel);

const state = {
    origin: null,       // { lon, lat, name }
    mode: 'walk',
    minutes: 15,
    bands: null,        // [{ minutes, geometry }] for current origin + mode
    aoi: null,
    themes: new Set(),
    mapTheme: null,
    token: 0,
};

let config, engine, mapView;

async function boot() {
    config = await loadConfig('.');
    let statewide = null;
    try {
        const r = await fetch('data/statewide.json', { cache: 'no-cache' });
        if (r.ok) statewide = await r.json();
    } catch { /* computed live instead */ }
    engine = new Engine(config, { statewide });
    mapView = new MapView('map', config.app);
    mapView.onMapClick(ll => setOrigin({ lon: ll.lng, lat: ll.lat }));

    state.minutes = config.app.isochrones.default_minutes;
    state.mode = config.app.isochrones.default_mode;
    for (const t of config.themes) state.themes.add(t.id);
    state.mapTheme = config.themes.find(t => t.map)?.id ?? null;

    renderModeButtons();
    renderTimeButtons();
    renderThemeButtons();
    wireSearch();
    wireResize();
    renderIntro();
    restoreFromHash();
}

/* --------------------------------------------------------------- controls */

function seg(wrap, items, current, onPick) {
    wrap.innerHTML = '';
    for (const { id, label, title } of items) {
        const b = document.createElement('button');
        b.type = 'button';
        b.setAttribute('role', 'radio');
        b.setAttribute('aria-checked', String(id === current));
        b.dataset.id = id;
        b.textContent = label;
        if (title) b.title = title;
        b.onclick = () => onPick(id);
        wrap.appendChild(b);
    }
}

function renderModeButtons() {
    const modes = config.app.isochrones.modes.map(id => ({ id, label: MODES[id].label }));
    seg($('#mode-buttons'), modes, state.mode, id => {
        if (id === state.mode) return;
        state.mode = id;
        renderModeButtons();
        if (state.origin) loadIsochrones();
        writeHash();
    });
}

function renderTimeButtons() {
    const times = config.app.isochrones.minutes.map(m => ({ id: m, label: `${m} min` }));
    seg($('#time-buttons'), times, state.minutes, m => {
        if (m === state.minutes) return;
        state.minutes = m;
        renderTimeButtons();
        if (state.bands) { mapView.showIsochrones(state.bands, state.minutes, { fit: false }); buildAoiAndReport(); }
        writeHash();
    });
}

function renderThemeButtons() {
    const wrap = $('#theme-buttons');
    wrap.innerHTML = '';
    for (const t of config.themes) {
        const b = document.createElement('button');
        b.type = 'button';
        b.dataset.id = t.id;
        b.style.setProperty('--c', t.color);
        b.setAttribute('aria-pressed', String(state.themes.has(t.id)));
        b.innerHTML = `<span class="dot"></span>${escapeHtml(t.label)}`;
        b.title = t.blurb || t.label;
        b.onclick = () => {
            if (state.themes.has(t.id)) state.themes.delete(t.id); else state.themes.add(t.id);
            b.setAttribute('aria-pressed', String(state.themes.has(t.id)));
            if (state.mapTheme && !state.themes.has(state.mapTheme)) state.mapTheme = orderedThemes().find(x => x.map)?.id ?? null;
            writeHash();
            if (state.aoi) renderReport(); else renderIntro();
        };
        wrap.appendChild(b);
    }
}

const orderedThemes = () => config.themes.filter(t => state.themes.has(t.id));

/* ----------------------------------------------------------------- origin */

function wireSearch() {
    const input = $('#place-input');
    const list = $('#place-results');
    let matches = [];
    let active = -1;
    let timer = null;
    let seq = 0;
    const close = () => { list.hidden = true; active = -1; };
    const render = () => {
        list.innerHTML = matches.map((f, i) =>
            `<li role="option" data-i="${i}" aria-selected="${i === active}">${escapeHtml(f.name)}${f.detail ? `<small>${escapeHtml(f.detail)}</small>` : ''}</li>`).join('');
        list.hidden = !matches.length;
    };
    input.addEventListener('input', () => {
        clearTimeout(timer);
        const q = input.value.trim();
        if (q.length < 3) { matches = []; render(); return; }
        timer = setTimeout(async () => {
            const my = ++seq;
            try { const r = await geocode(q); if (my === seq) { matches = r; active = -1; render(); } } catch (e) { console.warn(e); }
        }, 300);
    });
    input.addEventListener('keydown', e => {
        if (e.key === 'ArrowDown') { active = Math.min(matches.length - 1, active + 1); render(); e.preventDefault(); }
        else if (e.key === 'ArrowUp') { active = Math.max(0, active - 1); render(); e.preventDefault(); }
        else if (e.key === 'Enter') { const f = matches[active >= 0 ? active : 0]; if (f) { setOrigin(f); close(); input.blur(); } }
        else if (e.key === 'Escape') close();
    });
    list.addEventListener('mousedown', e => {
        const li = e.target.closest('li');
        if (li) { setOrigin(matches[Number(li.dataset.i)]); close(); }
    });
    input.addEventListener('blur', () => setTimeout(close, 150));
}

async function setOrigin(o) {
    state.origin = { lon: +o.lon, lat: +o.lat, name: o.name || null };
    $('#map-hint').hidden = true;
    mapView.setOrigin([state.origin.lon, state.origin.lat]);
    if (!state.origin.name) {
        $('#place-input').value = `${state.origin.lat.toFixed(4)}, ${state.origin.lon.toFixed(4)}`;
        reverseName(state.origin);
    } else {
        $('#place-input').value = state.origin.name;
    }
    writeHash();
    await loadIsochrones();
}

async function reverseName(o) {
    try {
        const r = await fetch(`https://photon.komoot.io/reverse?lon=${o.lon}&lat=${o.lat}&limit=1`);
        const p = (await r.json()).features?.[0]?.properties;
        if (!p || state.origin !== o) return;
        o.name = p.name || [p.housenumber, p.street].filter(Boolean).join(' ') || p.city || null;
        if (o.name) {
            $('#place-input').value = o.name + (p.city && p.name !== p.city ? `, ${p.city}` : '');
            const h = $('#report .report-head h2');
            if (h) h.textContent = headTitle();
        }
    } catch { /* keep coordinates */ }
}

async function loadIsochrones() {
    const token = ++state.token;
    state.bands = null;
    state.aoi = null;
    mapView.clearHexChoropleth();
    $('#report').innerHTML = `<div class="intro"><p>Finding everywhere within ${config.app.isochrones.minutes.join(', ')} minutes by ${MODES[state.mode].label.toLowerCase()}…</p></div>`;
    try {
        const bands = await fetchIsochrones(config.app.routing, state.origin, state.mode, config.app.isochrones.minutes);
        if (token !== state.token) return;
        state.bands = bands;
        mapView.showIsochrones(bands, state.minutes);
        buildAoiAndReport();
    } catch (err) {
        if (token !== state.token) return;
        $('#report').innerHTML = `<div class="err">Could not compute travel times here: ${escapeHtml(shortErr(err))}</div>`;
        console.error(err);
    }
}

function buildAoiAndReport() {
    state.token++;
    state.aoi = bandsAoi(state.bands, state.minutes, headTitle(), state.origin);
    renderReport();
}

/* ----------------------------------------------------------------- report */

function headTitle() {
    const o = state.origin;
    const where = o?.name || (o ? `${o.lat.toFixed(4)}, ${o.lon.toFixed(4)}` : '');
    return `${state.minutes}-minute ${MODES[state.mode].label.toLowerCase()} from ${where}`;
}

function renderIntro() {
    const themeList = config.themes.map(t => `<li><b>${escapeHtml(t.label)}</b> — ${escapeHtml(t.blurb || '')}</li>`).join('');
    $('#report').innerHTML = `
        <div class="intro">
            <h2>What nature is within reach?</h2>
            <p>Pick a starting point anywhere in California — click the map or search an address — then choose how you travel and how long you're willing to go.
               We map everywhere reachable in 5, 10 and 15 minutes along real streets and paths, and summarize what's inside.</p>
            <ul>${themeList}</ul>
            <p class="tile-note">Travel times come from the open-source Valhalla router on OpenStreetMap. All numbers are computed on demand with fixed, reviewable SQL — no AI model is involved.</p>
        </div>`;
    syncMapChips();
}

function renderReport() {
    const token = state.token;
    const aoi = state.aoi;
    const r = $('#report');
    r.innerHTML = `
        <div class="report-head">
            <div>
                <div class="kind">Reachable area</div>
                <h2>${escapeHtml(headTitle())}</h2>
                <div class="band-legend">${config.app.isochrones.minutes.map((m, i) =>
                    `<span><i class="${m === state.minutes ? '' : 'dash'}" style="border-color:${['#0f5132', '#2f8f5b', '#7cc59a'][i] || '#b9e3c6'}"></i>${m} min</span>`).join('')}</div>
            </div>
            <div class="head-actions">
                <button class="ghost-btn" id="export-btn" type="button" title="Download this profile as a report: map, numbers, charts, code (SQL / R / Python) and data citations">Export</button>
                <button class="ghost-btn" id="copy-link" type="button" title="Copy a link to this view">Copy link</button>
            </div>
        </div>`;
    $('#copy-link').onclick = async () => {
        try { await navigator.clipboard.writeText(location.href); $('#copy-link').textContent = 'Copied'; } catch { /* ignore */ }
    };
    wireExportButton($('#export-btn'), () => ({
        engine, aoi, mapView, kind: `${state.minutes}-minute ${MODES[state.mode].label.toLowerCase()}`,
        themes: [config.overview, ...orderedThemes()],
        reportEl: r, legendEl: $('#map-legend'), siteTitle: config.app.title,
    }));
    const opts = { isCurrent: () => token === state.token, onMapToggle: id => setMapTheme(state.mapTheme === id ? null : id), compareLabel: config.app.compare_label || 'California' };
    r.appendChild(renderThemeCard(engine, config.overview, aoi, { ...opts, overview: true }));
    for (const t of orderedThemes()) r.appendChild(renderThemeCard(engine, t, aoi, opts));
    syncMapChips();
    refreshMap();
}

/* -------------------------------------------------------------------- map */

function syncMapChips() {
    const wrap = $('#map-chips');
    const themes = orderedThemes().filter(t => t.map);
    if (!state.aoi || !themes.length) { wrap.hidden = true; return; }
    wrap.hidden = false;
    wrap.innerHTML = '<span class="lbl">Color map by</span>' + themes.map(t =>
        `<button class="map-btn" type="button" data-theme="${t.id}" style="--c:${t.color}" aria-pressed="${state.mapTheme === t.id}">${escapeHtml(t.label)}</button>`).join('');
    wrap.querySelectorAll('button').forEach(b => { b.onclick = () => setMapTheme(state.mapTheme === b.dataset.theme ? null : b.dataset.theme); });
    document.querySelectorAll('#report .map-btn').forEach(b => {
        b.setAttribute('aria-pressed', String(state.mapTheme === b.dataset.theme));
        b.textContent = state.mapTheme === b.dataset.theme ? 'On map' : 'Show on map';
    });
}

function setMapTheme(id) {
    state.mapTheme = id;
    writeHash();
    syncMapChips();
    refreshMap();
}

async function refreshMap() {
    const legend = $('#map-legend');
    const theme = state.mapTheme && config.themes.find(t => t.id === state.mapTheme);
    mapView.clearChoropleth();
    mapView.clearHexChoropleth();
    if (!state.aoi || !theme?.map) { legend.hidden = true; return; }
    const token = state.token;
    legend.hidden = false;
    legend.innerHTML = `<div class="title">${escapeHtml(theme.map.label)}</div><div class="tile-note">Loading…</div>`;
    try {
        const rows = await engine.run(theme, theme.map.query, state.aoi);
        if (token !== state.token || state.mapTheme !== theme.id) return;
        const info = theme.map.type === 'hex'
            ? await mapView.setHexChoropleth(theme.map, rows)
            : await mapView.setChoropleth(theme.map, rows);
        renderLegend(legend, theme.map, info);
    } catch (err) {
        if (token !== state.token) return;
        legend.innerHTML = `<div class="err">Map query failed: ${escapeHtml(shortErr(err))}</div>`;
        console.error(err, err.sql);
    }
}

/* ------------------------------------------------------------------- hash */

function writeHash() {
    const q = new URLSearchParams();
    q.set('mode', state.mode);
    q.set('t', state.minutes);
    if (state.themes.size !== config.themes.length) q.set('themes', orderedThemes().map(t => t.id).join(','));
    if (state.mapTheme) q.set('map', state.mapTheme);
    const o = state.origin ? `@${state.origin.lat.toFixed(5)},${state.origin.lon.toFixed(5)}` : '';
    history.replaceState(null, '', '#' + o + '?' + q.toString().replace(/%2C/g, ','));
}

function restoreFromHash() {
    const h = location.hash.slice(1);
    if (!h) return;
    const [path, query] = h.split('?');
    const q = new URLSearchParams(query || '');
    if (MODES[q.get('mode')] && config.app.isochrones.modes.includes(q.get('mode'))) state.mode = q.get('mode');
    const t = Number(q.get('t'));
    if (config.app.isochrones.minutes.includes(t)) state.minutes = t;
    if (q.has('themes')) {
        state.themes.clear();
        for (const id of q.get('themes').split(',')) if (config.themes.some(x => x.id === id)) state.themes.add(id);
    }
    if (q.get('map') && state.themes.has(q.get('map'))) state.mapTheme = q.get('map');
    renderModeButtons();
    renderTimeButtons();
    renderThemeButtons();
    const m = /^@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)/.exec(path || '');
    if (m) setOrigin({ lat: +m[1], lon: +m[2] });
}

/* ----------------------------------------------------------------- resize */

function wireResize() {
    const handle = document.querySelector('.sidebar-resize');
    const sidebar = $('#sidebar');
    try {
        const f = Number(localStorage.getItem('sidebar-frac'));
        if (f > 0.2 && f < 0.85) document.documentElement.style.setProperty('--sidebar-width', (f * 100).toFixed(1) + 'vw');
    } catch { /* storage unavailable */ }
    handle.addEventListener('pointerdown', e => {
        handle.setPointerCapture(e.pointerId);
        const move = ev => {
            const w = Math.max(360, Math.min(window.innerWidth - 320, window.innerWidth - ev.clientX));
            document.documentElement.style.setProperty('--sidebar-width', w + 'px');
            mapView.map.resize();
        };
        handle.addEventListener('pointermove', move);
        handle.addEventListener('pointerup', () => {
            handle.removeEventListener('pointermove', move);
            try { localStorage.setItem('sidebar-frac', parseInt(getComputedStyle(sidebar).width) / window.innerWidth); } catch { /* ignore */ }
        }, { once: true });
    });
}

boot().catch(err => {
    console.error(err);
    $('#report').innerHTML = `<div class="err">Failed to start: ${escapeHtml(err.message)}</div>`;
});
