// ==UserScript==
// @name         dsh-browser-bridge
// @namespace    https://github.com/xkzm123/dsh-browser-bridge
// @version      1.3.1
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
        items: (a) => {
            const sel = a.selector || 'a[href]';
            const limit = a.limit ?? 40;
            const needle = String(a.text || '').toLowerCase();
            const out = [];
            const seen = new Set();
            for (const el of document.querySelectorAll(sel)) {
                const t = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
                if (!t) continue;
                if (needle && !t.toLowerCase().includes(needle)) continue;
                const href = el.href || el.getAttribute('href') || '';
                const key = t + '|' + href;
                if (seen.has(key)) continue;
                seen.add(key);
                out.push({ text: t.slice(0, 160), href: String(href).slice(0, 300) });
                if (out.length >= limit) break;
            }
            return out;
        },
        attrs: (a) => {
            const el = pick(a.selector);
            const r = el.getBoundingClientRect();
            const attrs = {};
            for (const name of ['id', 'class', 'href', 'src', 'alt', 'title', 'role', 'aria-label', 'aria-pressed', 'aria-selected', 'aria-checked', 'aria-expanded', 'data-title']) {
                const v = el.getAttribute(name);
                if (v !== null && v !== '') attrs[name] = String(v).slice(0, 200);
            }
            return {
                tag: el.tagName.toLowerCase(),
                text: (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 300),
                attrs,
                rect: [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)],
            };
        },
        clickText: async (a) => {
            const needle = String(a.text || '');
            if (!needle) throw new Error('clickText needs a text argument');
            const root = a.selector ? pick(a.selector) : document.body;
            const lower = needle.toLowerCase();
            let best = null;
            for (const el of root.querySelectorAll('a,button,[role="button"],[onclick],li,span,strong,p')) {
                const t = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
                if (!t) continue;
                const hit = a.exactly ? t.toLowerCase() === lower : t.toLowerCase().includes(lower);
                if (!hit) continue;
                if (!best || t.length < best.len) best = { el, len: t.length, text: t };
            }
            if (!best) throw new Error('no element whose visible text contains "' + needle + '"; nothing was clicked');
            const el = best.el;
            try { el.scrollIntoView({ block: 'center', behavior: 'instant' }); } catch { el.scrollIntoView(); }
            const before = el.className;
            el.click();
            // 点完顺手读一次自身状态，把「变了没有」直接回传，免掉一次截图或一次往返
            await new Promise((r) => setTimeout(r, a.settleMs ?? 300));
            const attrs = {};
            for (const name of ['class', 'aria-pressed', 'aria-selected', 'aria-checked', 'aria-expanded', 'href', 'data-title']) {
                const v = el.getAttribute ? el.getAttribute(name) : null;
                if (v !== null && v !== '') attrs[name] = String(v).slice(0, 200);
            }
            return {
                clicked: best.text.slice(0, 80),
                tag: el.tagName.toLowerCase(),
                changed: before !== el.className,
                after: attrs,
                pageText: document.body ? document.body.innerText.slice(0, 120).replace(/\s+/g, ' ') : '',
            };
        },
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
        waitFor: async (a) => {
            const timeout = a.timeoutMs ?? 8000;
            const needle = a.text ? String(a.text).toLowerCase() : null;
            const sel = a.selector || null;
            if (!needle && !sel) throw new Error('waitFor needs selector or text');
            const t0 = performance.now();
            for (;;) {
                let hit = null;
                if (sel) {
                    const el = document.querySelector(sel);
                    if (el) hit = { kind: 'selector', el };
                }
                if (!hit && needle) {
                    const body = document.body ? document.body.innerText.toLowerCase() : '';
                    if (body.includes(needle)) hit = { kind: 'text', el: document.body };
                }
                if (hit) {
                    const r = hit.el.getBoundingClientRect ? hit.el.getBoundingClientRect() : null;
                    return {
                        found: true,
                        by: hit.kind,
                        ms: Math.round(performance.now() - t0),
                        text: (hit.el.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 200),
                        rect: r ? [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)] : null,
                    };
                }
                if (performance.now() - t0 > timeout) {
                    return { found: false, ms: Math.round(performance.now() - t0), url: location.href };
                }
                await new Promise((r) => setTimeout(r, a.intervalMs ?? 250));
            }
        },
        batch: async (a) => {
            const steps = a.steps || [];
            if (!Array.isArray(steps) || steps.length === 0) throw new Error('batch needs a non-empty steps array');
            const out = [];
            for (const step of steps) {
                const fn = OPS[step.op];
                if (!fn) { out.push({ op: step.op, ok: false, error: 'unknown op' }); continue; }
                try {
                    const value = fn(step.args ?? {});
                    out.push({ op: step.op, ok: true, value: value instanceof Promise ? await value : value });
                } catch (e) {
                    out.push({ op: step.op, ok: false, error: String((e && e.message) || e) });
                    if (a.stopOnError !== false) break;
                }
            }
            return out;
        },
        scrollBy: (a) => { window.scrollBy(a.x ?? 0, a.y ?? 0); return 'scrolled'; },
    };

    async function runOp(op, args) {
        const fn = OPS[op];
        if (!fn) throw new Error(`unknown op "${op}"; available: ${Object.keys(OPS).join(', ')}`);
        const value = fn(args ?? {});
        return value instanceof Promise ? await value : value;
    }

    async function runJob(job) {
        const t0 = performance.now();
        if (job.op) {
            const value = await runOp(job.op, job.args);
            return { value: stringify(value), ms: Math.round(performance.now() - t0) };
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

    /** 等这个标签页变成可见，最多 ms 毫秒；超时返回 false。 */
    function waitVisible(ms) {
        if (document.visibilityState === 'visible') return Promise.resolve(true);
        return new Promise((resolve) => {
            const t0 = Date.now();
            const timer = setInterval(() => {
                if (document.visibilityState === 'visible') { clearInterval(timer); resolve(true); return; }
                if (Date.now() - t0 > ms) { clearInterval(timer); resolve(false); }
            }, 120);
        });
    }

    async function loop() {
        if (busy) { setTimeout(loop, POLL_MS); return; }
        busy = true;
        try {
            // 隐藏的标签页也轮询：否则浏览器不是前台窗口时桥会完全失效。
            // 拿到任务后先等它变成可见，最多 3 秒；还是不可见就把任务还回队列，
            // 让当前可见的那个标签页去执行，避免在后台页面上误操作。
            const job = await get('/poll');
            if (job && job.id) {
                const visible = await waitVisible(3000);
                if (!visible) {
                    await post('/requeue', { id: job.id });
                    busy = false;
                    setTimeout(loop, POLL_MS * 2);
                    return;
                }
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
        setTimeout(loop, document.visibilityState === 'visible' ? POLL_MS : POLL_MS * 2);
    }

    window.__DSH_BRIDGE__ = {
        port: PORT,
        version: '1.3.1',
        eval: evalOk,
        ops: Object.keys(OPS),
        ping: () => get('/ping'),
    };

    setTimeout(loop, 800);
})();
