// ==UserScript==
// @name         dsh-browser-bridge
// @namespace    https://github.com/xkzm123/dsh-browser-bridge
// @version      1.1.0
// @description  Lets a DeepSeek Harness session read and drive an already-running browser, without restarting it or enabling remote debugging.
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

    // Pages with a strict CSP (github.com and friends) block eval inside this
    // sandbox, so arbitrary JavaScript is not always available. The fixed
    // operation vocabulary below does not need eval and works everywhere.
    let evalOk = true;
    try {
        const AsyncFunction = Object.getPrototypeOf(async function () { }).constructor;
        void new AsyncFunction('return 1');
    } catch {
        evalOk = false;
    }

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
        } catch {
            return String(value);
        }
    }

    const pick = (selector) => {
        const el = document.querySelector(selector);
        if (!el) throw new Error(`no element matches ${selector}`);
        return el;
    };

    /** Fixed operations that never need eval, so a page CSP cannot block them. */
    const OPS = {
        title: () => document.title,
        url: () => location.href,
        text: () => (document.body ? document.body.innerText : ''),
        html: (a) => (a.selector ? pick(a.selector) : document.documentElement).outerHTML,
        links: () => Array.from(document.querySelectorAll('a')).map((x) => x.href),
        query: (a) => Array.from(document.querySelectorAll(a.selector)).map((el) => {
            if (a.attr) return el.getAttribute(a.attr);
            if (a.prop) return el[a.prop];
            return el.textContent;
        }),
        count: (a) => document.querySelectorAll(a.selector).length,
        click: (a) => { pick(a.selector).click(); return 'clicked'; },
        fill: (a) => {
            const el = pick(a.selector);
            el.focus();
            el.value = a.value ?? '';
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
            return 'filled';
        },
        submit: (a) => {
            const el = pick(a.selector);
            const form = el.form ?? el.closest('form');
            if (!form) throw new Error('no form for ' + a.selector);
            form.submit();
            return 'submitted';
        },
        cookies: () => document.cookie,
        storage: (a) => JSON.stringify(a.store === 'session' ? { ...sessionStorage } : { ...localStorage }),
        meta: (a) => {
            const el = document.querySelector(`meta[name="${a.name}"], meta[property="${a.name}"]`);
            return el ? el.getAttribute('content') : null;
        },
        scrollTo: (a) => { window.scrollTo(a.x ?? 0, a.y ?? 0); return 'scrolled'; },
        scrollBy: (a) => { window.scrollBy(a.x ?? 0, a.y ?? 0); return 'scrolled'; },
    };

    function runOp(op, args) {
        const fn = OPS[op];
        if (!fn) throw new Error(`unknown op "${op}"; available: ${Object.keys(OPS).join(', ')}`);
        return fn(args ?? {});
    }

    async function runJob(job) {
        const t0 = performance.now();
        if (job.op) {
            return { value: stringify(runOp(job.op, job.args)), ms: Math.round(performance.now() - t0) };
        }
        if (!evalOk) {
            throw new Error(
                'this page\'s Content Security Policy blocks eval, so arbitrary JavaScript cannot run here. '
                + `Use the operation vocabulary instead: ${Object.keys(OPS).join(', ')}.`,
            );
        }
        const AsyncFunction = Object.getPrototypeOf(async function () { }).constructor;
        const helpers = `
            const __q = (s) => document.querySelector(s);
            const __qa = (s) => Array.from(document.querySelectorAll(s));
            const __text = () => document.body ? document.body.innerText : '';
            const __click = (s) => { const e = typeof s === 'string' ? document.querySelector(s) : s; if (e) e.click(); return !!e; };
            const __sleep = (ms) => new Promise(r => setTimeout(r, ms));
        `;
        const value = await (new AsyncFunction(helpers + job.code))();
        if (value !== undefined) {
            return { value: stringify(value), ms: Math.round(performance.now() - t0) };
        }
        // the code was a bare expression, e.g. "document.title + location.href"
        let fallback;
        try {
            fallback = await (new AsyncFunction(helpers + 'return (' + job.code + ');'))();
        } catch {
            fallback = undefined;
        }
        return { value: stringify(fallback), ms: Math.round(performance.now() - t0) };
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
                    eval: evalOk,
                    ok: true,
                };
                try {
                    const r = await runJob(job);
                    payload.value = `[${r.ms}ms] ` + r.value;
                } catch (e) {
                    payload.ok = false;
                    payload.error = String(e && e.message ? e.message : e);
                }
                await post('/result', payload);
            }
        } catch {
            /* server down; keep quiet */
        }
        busy = false;
        setTimeout(loop, POLL_MS);
    }

    window.__DSH_BRIDGE__ = {
        port: PORT,
        version: '1.1.0',
        eval: evalOk,
        ops: Object.keys(OPS),
        ping: () => get('/ping'),
    };

    setTimeout(loop, 800);
})();
