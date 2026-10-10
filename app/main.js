/**
 * App controller: jurisdiction type → dimensions → place → report + map.
 * State is mirrored to the URL hash (#county/06001?themes=a,b&map=a) so a
 * profile is a shareable link.
 */

import { loadConfig, Engine, jurisdictionAoi } from './engine.js';
import { MapView, renderLegend } from './map.js';
import { renderBarChart } from './charts.js';
import { fmt, escapeHtml } from './format.js';

const $ = sel => document.querySelector(sel);

const state = {
    jur: null,          // jurisdiction config
    themes: new Set(),  // selected theme ids (order follows config)
    feature: null,      // { id, name, ... } from the pick list
    aoi: null,
    mapTheme: null,     // theme id coloring the tracts, or null
    features: [],       // pick list for current jurisdiction
    token: 0,           // bumps on every AOI change; stale results are dropped
};

let config, engine, mapView;

async function boot() {
    config = await loadConfig('.');
    let statewide = null;
    try {
        const r = await fetch('data/statewide.json', { cache: 'no-cache' });
        if (r.ok) statewide = await r.json();
    } catch { /* computed live instead */ }

    // Optional runtime override (k8s writes config.json with the MCP URL).
    let mcpUrl = config.app.mcp_url;
    try {
        const r = await fetch('config.json', { cache: 'no-cache' });
        if (r.ok) mcpUrl = (await r.json()).mcp_server_url || mcpUrl;
    } catch { /* default */ }

    engine = new Engine(config, { mcpUrl, statewide });
    mapView = new MapView('map', config.app);
    mapView.onPick = id => pickById(id);

    for (const t of config.themes) state.themes.add(t.id);   // all dimensions on by default
    state.mapTheme = config.themes[0]?.id ?? null;
    renderJurButtons();
    renderThemeButtons();
    wireSearch();
    wireResize();
    renderIntro();
    await restoreFromHash();
    updateSteps();
}

/* ------------------------------------------------------------------ steps */

function renderJurButtons() {
    const wrap = $('#jur-buttons');
    wrap.innerHTML = '';
    for (const j of config.app.jurisdictions) {
        const b = document.createElement('button');
        b.type = 'button';
        b.setAttribute('role', 'radio');
        b.setAttribute('aria-checked', 'false');
        b.dataset.id = j.id;
        b.textContent = j.label;
        b.title = j.description || j.label;
        b.onclick = () => setJurisdiction(j.id);
        wrap.appendChild(b);
    }
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
        b.onclick = () => toggleTheme(t.id);
        wrap.appendChild(b);
    }
}

async function setJurisdiction(id, { keepFeature = false } = {}) {
    const jur = config.app.jurisdictions.find(j => j.id === id);
    if (!jur) return;
    state.jur = jur;
    document.querySelectorAll('#jur-buttons button').forEach(b => b.setAttribute('aria-checked', String(b.dataset.id === id)));
    $('#place-label').textContent = jur.singular || jur.label;
    const input = $('#place-input');
    input.disabled = false;
    input.value = '';
    input.placeholder = `Loading ${jur.label.toLowerCase()}…`;
    if (!keepFeature) {
        state.feature = null;
        state.aoi = null;
        state.token++;
        mapView.clearChoropleth?.();
        renderIntro();
        syncMapChips();
    }
    await mapView.showJurisdiction(jur);
    showHint(`Click a ${(jur.singular || jur.label).toLowerCase()} on the map, or search by name`);
    try {
        state.features = await engine.listFeatures(jur);
        state.features.sort((a, b) => naturalCompare(a.name, b.name));
        input.placeholder = `Search ${state.features.length} ${jur.label.toLowerCase()}…`;
    } catch (err) {
        input.placeholder = 'Could not load list — click the map instead';
        console.error(err);
    }
    $('#place-help').textContent = '';
    updateSteps();
    writeHash();
}

function toggleTheme(id) {
    if (state.themes.has(id)) state.themes.delete(id); else state.themes.add(id);
    document.querySelectorAll('#theme-buttons button').forEach(b => b.setAttribute('aria-pressed', String(state.themes.has(b.dataset.id))));
    if (state.mapTheme && !state.themes.has(state.mapTheme)) state.mapTheme = null;
    if (!state.mapTheme && state.themes.size) state.mapTheme = orderedThemes()[0].id;
    updateSteps();
    writeHash();
    if (state.aoi) renderReport();
    else renderIntro();
}

function orderedThemes() {
    return config.themes.filter(t => state.themes.has(t.id));
}

function updateSteps() {
    $('#step-jur').classList.toggle('pending', !state.jur);
    $('#step-themes').classList.toggle('pending', !state.themes.size);
    $('#step-place').classList.toggle('pending', !state.feature);
}

/* ----------------------------------------------------------------- search */

function wireSearch() {
    const input = $('#place-input');
    const list = $('#place-results');
    let matches = [];
    let active = -1;

    const close = () => { list.hidden = true; active = -1; };
    const render = () => {
        const q = input.value.trim().toLowerCase();
        matches = (q ? state.features.filter(f => f.name.toLowerCase().includes(q)) : state.features).slice(0, 50);
        list.innerHTML = matches.map((f, i) =>
            `<li role="option" data-i="${i}" aria-selected="${i === active}">${escapeHtml(f.name)}${f.detail ? `<small>${escapeHtml(f.detail)}</small>` : ''}</li>`).join('');
        list.hidden = !matches.length;
    };
    input.addEventListener('input', () => { active = -1; render(); });
    input.addEventListener('focus', render);
    input.addEventListener('keydown', e => {
        if (e.key === 'ArrowDown') { active = Math.min(matches.length - 1, active + 1); render(); e.preventDefault(); }
        else if (e.key === 'ArrowUp') { active = Math.max(0, active - 1); render(); e.preventDefault(); }
        else if (e.key === 'Enter') {
            const f = matches[active >= 0 ? active : 0];
            if (f) { pick(f); close(); input.blur(); }
        } else if (e.key === 'Escape') close();
    });
    list.addEventListener('mousedown', e => {
        const li = e.target.closest('li');
        if (!li) return;
        pick(matches[Number(li.dataset.i)]);
        close();
    });
    input.addEventListener('blur', () => setTimeout(close, 150));
}

function pickById(id) {
    const f = state.features.find(x => String(x.id) === String(id));
    pick(f || { id, name: `${state.jur.singular || state.jur.label} ${id}` });
}

function pick(feature) {
    if (!feature || !state.jur) return;
    state.feature = feature;
    state.aoi = jurisdictionAoi(state.jur, feature);
    state.token++;
    $('#place-input').value = feature.name;
    hideHint();
    const bbox = ['xmin', 'ymin', 'xmax', 'ymax'].map(k => Number(feature[k]));
    mapView.select(feature.id, bbox);
    if (!state.mapTheme && state.themes.size) state.mapTheme = orderedThemes()[0].id;
    updateSteps();
    writeHash();
    renderReport();
}

/* ----------------------------------------------------------------- report */

function renderIntro() {
    const r = $('#report');
    const themeList = config.themes.map(t => `<li><b>${escapeHtml(t.label)}</b> — ${escapeHtml(t.blurb || '')}</li>`).join('');
    r.innerHTML = `
        <div class="intro">
            <h2>How does a place compare?</h2>
            <p>Pick a type of jurisdiction, choose the dimensions you care about, then select a place by name or on the map.
               Each profile compares the place with California as a whole, and splits key measures between land that is
               protected under the state's 30x30 definition (GAP 1–2) and land that is not.</p>
            <ul>${themeList}</ul>
            <p class="tile-note">All numbers are computed on demand from public datasets with fixed, reviewable SQL — no AI model is involved.
               Open “Method &amp; SQL” under any panel to see exactly what ran.</p>
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
                <div class="kind">${escapeHtml(state.jur.singular || state.jur.label)}</div>
                <h2>${escapeHtml(aoi.label)}</h2>
            </div>
            <button class="ghost-btn" id="copy-link" type="button" title="Copy a link to this profile">Copy link</button>
        </div>`;
    $('#copy-link').onclick = async () => {
        try { await navigator.clipboard.writeText(location.href); $('#copy-link').textContent = 'Copied'; } catch { /* ignore */ }
    };

    r.appendChild(themeCard(config.overview, aoi, token, { overview: true }));
    if (!state.themes.size) {
        const n = document.createElement('div');
        n.className = 'card';
        n.innerHTML = '<p class="card-blurb" style="margin:0">Select one or more <b>dimensions</b> above to add biodiversity, health &amp; equity, or climate-risk panels.</p>';
        r.appendChild(n);
    }
    for (const t of orderedThemes()) r.appendChild(themeCard(t, aoi, token));
    syncMapChips();
    refreshChoropleth();
}

function themeCard(theme, aoi, token, { overview = false } = {}) {
    const card = document.createElement('section');
    card.className = 'card' + (overview ? '' : ' theme-card');
    card.style.setProperty('--c', theme.color || 'var(--primary)');
    card.innerHTML = `
        <div class="card-head">
            <h3>${overview ? '' : '<span class="dot"></span>'}${escapeHtml(theme.label)}</h3>
            ${!overview && theme.map ? `<button class="map-btn" type="button" data-theme="${theme.id}">Show on map</button>` : ''}
        </div>
        ${theme.blurb && !overview ? `<p class="card-blurb">${escapeHtml(theme.blurb)}</p>` : ''}
        <div class="tiles"></div>
        <div class="charts"></div>
        <details class="method"><summary>Method &amp; SQL</summary><div class="method-body"></div></details>`;

    const mapBtn = card.querySelector('.map-btn');
    if (mapBtn) mapBtn.onclick = () => setMapTheme(state.mapTheme === theme.id ? null : theme.id);

    const tiles = card.querySelector('.tiles');
    tiles.dataset.n = (theme.headlines || []).length;
    for (const h of theme.headlines || []) {
        const t = document.createElement('div');
        t.className = 'tile skeleton';
        t.innerHTML = `<div class="tile-label">${escapeHtml(h.label)}</div><div class="tile-value">0000</div><div class="tile-compare">&nbsp;</div>`;
        tiles.appendChild(t);
        Promise.all([engine.run(theme, h.query, aoi), h.compare === false ? null : engine.runStatewide(theme, h.query).catch(() => null)])
            .then(([rows, st]) => {
                if (token !== state.token) return;
                t.classList.remove('skeleton');
                const row = pickRow(rows, h.row);
                const v = row?.[h.field];
                const sv = pickRow(st, h.row)?.[h.compare_field || h.field];
                t.innerHTML = `
                    <div class="tile-label">${escapeHtml(h.label)}</div>
                    <div class="tile-value">${fmt(v, h.format)}</div>
                    ${h.compare !== false && sv !== undefined && sv !== null ? `<div class="tile-compare">California: ${fmt(sv, h.compare_format || h.format)}</div>` : ''}
                    ${h.detail_field && row?.[h.detail_field] != null ? `<div class="tile-note">${escapeHtml(h.detail_template.replace('{}', fmt(row[h.detail_field], h.detail_format)))}</div>` : ''}
                    ${h.note ? `<div class="tile-note">${escapeHtml(h.note)}</div>` : ''}`;
            })
            .catch(err => failTile(t, h, err, token));
    }

    const charts = card.querySelector('.charts');
    for (const c of theme.charts || []) {
        const box = document.createElement('div');
        box.className = 'chart' + (c.wide ? ' wide' : '');
        box.innerHTML = `<h4>${escapeHtml(c.title)}</h4>${c.subtitle ? `<div class="sub">${escapeHtml(c.subtitle)}</div>` : ''}<div class="plot skeleton" style="height:120px"></div>`;
        charts.appendChild(box);
        const plot = box.querySelector('.plot');
        const wantState = c.compare || c.statewide_row;
        const load = c.pivot
            ? pivotRows(theme, c, aoi).then(rows => [rows, null])
            : Promise.all([engine.run(theme, c.query, aoi), wantState ? engine.runStatewide(theme, c.query).catch(() => null) : null]);
        load
            .then(([rows, st]) => {
                if (token !== state.token) return;
                plot.classList.remove('skeleton');
                plot.style.height = '';
                if (c.statewide_row) {
                    // one-row result → compare this place and California side by side
                    rows = [{ ...rows?.[0], __label: shortLabel(aoi.label) }];
                    if (st?.[0]) rows.push({ ...st[0], __label: 'California' });
                    st = null;
                }
                renderBarChart(plot, c, rows, st);
            })
            .catch(err => {
                if (token !== state.token) return;
                plot.classList.remove('skeleton');
                plot.style.height = '';
                plot.innerHTML = `<div class="err">Query failed: ${escapeHtml(shortErr(err))}</div>`;
                console.error(err, err.sql);
            });
    }

    // method + exact SQL as run for this area
    const mb = card.querySelector('.method-body');
    card.querySelector('details').addEventListener('toggle', function once() {
        mb.innerHTML = (theme.method ? `<p>${escapeHtml(theme.method)}</p>` : '') +
            Object.keys(theme.queries)
                .map(q => `<div><b>${escapeHtml(q)}</b></div><pre>${escapeHtml(engine.sqlFor(theme, q, aoi))}</pre>`).join('');
    }, { once: true });
    return card;
}

function failTile(t, h, err, token) {
    if (token !== state.token) return;
    t.classList.remove('skeleton');
    t.innerHTML = `<div class="tile-label">${escapeHtml(h.label)}</div><div class="tile-value">—</div><div class="err" title="${escapeHtml(err.message)}">Query failed</div>`;
    console.error(err, err.sql);
}

/**
 * Build chart rows from one-row results of several queries:
 *   pivot: [{ label, query, fields: { seriesField: resultColumn } }]
 */
async function pivotRows(theme, c, aoi) {
    const queries = [...new Set(c.pivot.map(p => p.query))];
    const results = Object.fromEntries(await Promise.all(queries.map(async q => [q, (await engine.run(theme, q, aoi))?.[0] || {}])));
    return c.pivot.map(p => {
        const row = { __label: p.label };
        for (const [k, col] of Object.entries(p.fields)) row[k] = results[p.query][col];
        return row;
    });
}

/** First row, or the row whose fields match `where` (e.g. {"grp": "DAC tracts"}). */
function pickRow(rows, where) {
    if (!rows) return null;
    if (!where) return rows[0];
    return rows.find(r => Object.entries(where).every(([k, v]) => r[k] === v)) || null;
}

const shortLabel = s => String(s).replace(/^(Congressional|State Senate|Assembly) District /, (m, k) => ({ Congressional: 'CD ', 'State Senate': 'SD ', Assembly: 'AD ' }[k]));

const shortErr = err => (err.message || String(err)).split('\n')[0].slice(0, 160);

/* -------------------------------------------------------------------- map */

function syncMapChips() {
    const wrap = $('#map-chips');
    const themes = orderedThemes().filter(t => t.map);
    if (!state.aoi || !themes.length) { wrap.hidden = true; return; }
    wrap.hidden = false;
    wrap.innerHTML = '<span class="lbl">Color tracts by</span>' + themes.map(t =>
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
    refreshChoropleth();
}

async function refreshChoropleth() {
    const legend = $('#map-legend');
    const theme = state.mapTheme && config.themes.find(t => t.id === state.mapTheme);
    if (!state.aoi || !theme || !theme.map) {
        mapView.clearChoropleth();
        legend.hidden = true;
        return;
    }
    const token = state.token;
    const want = theme.id;
    legend.hidden = false;
    legend.innerHTML = `<div class="title">${escapeHtml(theme.map.label)}</div><div class="tile-note">Loading tracts…</div>`;
    try {
        const rows = await engine.run(theme, theme.map.query, state.aoi);
        if (token !== state.token || state.mapTheme !== want) return;
        const info = await mapView.setChoropleth(theme.map, rows);
        renderLegend(legend, theme.map, info);
    } catch (err) {
        if (token !== state.token) return;
        legend.innerHTML = `<div class="err">Map query failed: ${escapeHtml(shortErr(err))}</div>`;
        console.error(err, err.sql);
    }
}

function showHint(text) { const h = $('#map-hint'); h.textContent = text; h.hidden = false; }
function hideHint() { $('#map-hint').hidden = true; }

/* ------------------------------------------------------------------- hash */

function writeHash() {
    const parts = [];
    if (state.jur) parts.push(state.jur.id);
    if (state.jur && state.feature) parts.push(encodeURIComponent(state.feature.id));
    const q = new URLSearchParams();
    if (state.themes.size !== config.themes.length) q.set('themes', orderedThemes().map(t => t.id).join(','));
    if (state.mapTheme) q.set('map', state.mapTheme);
    const hash = '#' + parts.join('/') + (q.toString() ? '?' + q.toString().replace(/%2C/g, ',') : '');
    history.replaceState(null, '', hash === '#' ? location.pathname : hash);
}

async function restoreFromHash() {
    const h = location.hash.slice(1);
    if (!h) return;
    const [path, query] = h.split('?');
    const q = new URLSearchParams(query || '');
    if (q.has('themes')) {
        state.themes.clear();
        for (const id of q.get('themes').split(',').filter(Boolean)) {
            if (config.themes.some(t => t.id === id)) state.themes.add(id);
        }
    }
    document.querySelectorAll('#theme-buttons button').forEach(b => b.setAttribute('aria-pressed', String(state.themes.has(b.dataset.id))));
    const map = q.get('map');
    state.mapTheme = map && state.themes.has(map) ? map : (state.themes.size ? orderedThemes()[0].id : null);
    const [jurId, featId] = path.split('/');
    if (jurId) {
        await setJurisdiction(jurId);
        if (featId) pickById(decodeURIComponent(featId));
    }
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
        const up = () => {
            handle.removeEventListener('pointermove', move);
            try { localStorage.setItem('sidebar-frac', parseInt(getComputedStyle(sidebar).width) / window.innerWidth); } catch { /* ignore */ }
        };
        handle.addEventListener('pointermove', move);
        handle.addEventListener('pointerup', up, { once: true });
    });
}

function naturalCompare(a, b) {
    return String(a).localeCompare(String(b), 'en', { numeric: true });
}

boot().catch(err => {
    console.error(err);
    $('#report').innerHTML = `<div class="err">Failed to start: ${escapeHtml(err.message)}</div>`;
});
