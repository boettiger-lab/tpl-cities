#!/usr/bin/env node
/**
 * Precompute the slow, shared results so the app opens fast:
 *   data/lists/<jurisdiction>.json   pick lists (id, name, bbox)
 *   data/statewide.json              every theme query run over all of California
 *
 * Uses the same engine + MCP client as the browser.
 *
 *   node scripts/precompute.mjs                 # everything
 *   node scripts/precompute.mjs lists           # pick lists only
 *   node scripts/precompute.mjs statewide [theme ...]
 */

import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadConfig, Engine, statewideAoi } from '../app/engine.js';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const fetchText = p => readFile(p, 'utf8');
const [what = 'all', ...only] = process.argv.slice(2);
const config = await loadConfig(root, fetchText, what === "lists" ? { themes: ["overview"] } : only.length ? { themes: only } : {});
const engine = new Engine(config, { mcpUrl: process.env.MCP_URL || config.app.mcp_url });

if (what === 'all' || what === 'lists') {
    await mkdir(`${root}/data/lists`, { recursive: true });
    for (const jur of config.app.jurisdictions) {
        const t0 = Date.now();
        const rows = await engine.client.query(jur.list);
        await writeFile(`${root}/data/lists/${jur.id}.json`, JSON.stringify(rows));
        console.log(`list ${jur.id}: ${rows.length} rows (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
    }
}

if (what === 'all' || what === 'statewide') {
    const file = `${root}/data/statewide.json`;
    let out = { generated: null, results: {} };
    try { out = JSON.parse(await readFile(file, 'utf8')); } catch { /* fresh */ }
    const aoi = statewideAoi(config.app);
    for (const theme of [config.overview, ...config.themes]) {
        if (only.length && !only.includes(theme.id)) continue;
        out.results[theme.id] ??= {};
        for (const [name, q] of Object.entries(theme.queries)) {
            if (q.statewide === false) continue;
            const t0 = Date.now();
            try {
                out.results[theme.id][name] = await engine.client.query(engine.sqlFor(theme, name, aoi));
                console.log(`statewide ${theme.id}.${name}: ok (${((Date.now() - t0) / 1000).toFixed(1)}s)`);
            } catch (err) {
                console.error(`statewide ${theme.id}.${name}: FAILED — ${err.message.split('\n')[0]}`);
            }
        }
    }
    out.generated = new Date().toISOString();
    await writeFile(file, JSON.stringify(out, null, 1));
}
