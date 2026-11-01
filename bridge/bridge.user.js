// ==UserScript==
// @name         dsh-browser-bridge
// @namespace    https://github.com/xkzm123/dsh-browser-bridge
// @version      1.0.1
// @description  Lets a DeepSeek Harness session run JavaScript in an already-running browser, without restarting it or enabling remote debugging.
// @author       xkzm123
// @match        *://*/*
// @connect      127.0.0.1
// @connect      localhost
// @grant        GM_xmlhttpRequest
// @run-at       document-idle
// @noframes
// ==/UserScript==

(function () {
    'use strict';

    const PORT = 8737;
    const BASE = `http://127.0.0.1:${PORT}`;
    const POLL_MS = 400;
    const MAX_RESULT = 200000;

    let busy = false;

    function post(path, data) {
        return new Promise((resolve) => {
            GM_xmlhttpRequest({
                method: 'POST',
                url: BASE + path,
                headers: { 'Content-Type': 'application/json' },
                data: JSON.stringify(data),
                timeout: 4000,
                onload: (r) => { try { resolve(JSON.parse(r.responseText)); } catch { resolve(null); } },
                onerror: () => resolve(null),
                ontimeout: () => resolve(null),
            });
        });
    }

    function get(path) {
        return new Promise((resolve) => {
            GM_xmlhttpRequest({
                method: 'GET',
                url: BASE + path,
                timeout: 4000,
                onload: (r) => { try { resolve(JSON.parse(r.responseText)); } catch { resolve(null); } },
                onerror: () => resolve(null),
                ontimeout: () => resolve(null),
            });
        });
    }

    function stringify(value) {
        if (value === undefined) return 'undefined';
        if (value === null) return 'null';
        if (typeof value === 'string') return value;
        if (typeof value === 'number' || typeof value === 'boolean') return String(value);
        try {
            const seen = new WeakSet();
            const out = JSON.stringify(value, (k, v) => {
                if (typeof v === 'object' && v !== null) {
                    if (seen.has(v)) return '[circular]';
                    seen.add(v);
                }
                return v;
            }, 2);
            return out && out.length > MAX_RESULT ? out.slice(0, MAX_RESULT) + '\n...[truncated]' : out;
        } catch (e) {
            return String(value);
        }
    }

    async function runJob(job) {
        const AsyncFunction = Object.getPrototypeOf(async function () { }).constructor;
        const t0 = performance.now();
        const helpers = `
            const __q = (s) => document.querySelector(s);
            const __qa = (s) => Array.from(document.querySelectorAll(s));
            const __text = () => document.body ? document.body.innerText : '';
            const __click = (s) => { const e = typeof s === 'string' ? document.querySelector(s) : s; if (e) e.click(); return !!e; };
            const __sleep = (ms) => new Promise(r => setTimeout(r, ms));
        `;
        let value;
        try {
            value = await (new AsyncFunction(helpers + job.code))();
        } catch (e) {
            throw e;
        }
        if (value === undefined) {
            // code was a bare expression (e.g. "document.title + ' | ' + location.href")
            try {
                value = await (new AsyncFunction(helpers + 'return (' + job.code + ');'))();
            } catch (e) {
                /* keep undefined */
            }
        }
        return { value: stringify(value), ms: Math.round(performance.now() - t0) };
    }

    async function loop() {
        if (busy) { setTimeout(loop, POLL_MS); return; }
        busy = true;
        try {
            if (document.visibilityState !== 'visible') { busy = false; setTimeout(loop, POLL_MS * 3); return; }
            const job = await get('/poll');
            if (job && job.id) {
                const payload = {
                    id: job.id,
                    url: location.href,
                    title: document.title,
                    ok: true,
                };
                try {
                    const r = await runJob(job);
                    payload.value = `[${r.ms}ms] ` + r.value;
                } catch (e) {
                    payload.ok = false;
                    payload.error = String(e && e.stack ? e.stack : e);
                }
                await post('/result', payload);
            }
        } catch (e) {
            /* server down; keep quiet */
        }
        busy = false;
        setTimeout(loop, POLL_MS);
    }

    // expose a tiny handshake so the agent can confirm the bridge is alive
    window.__DSH_BRIDGE__ = {
        port: PORT,
        version: '1.0.0',
        ping: () => get('/ping'),
    };

    setTimeout(loop, 800);
})();
