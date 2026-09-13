import { computed, runWithOwner, signal, setSignal } from "./core/core.js";

import { createOwner } from "./core/owner.js";

import "./core/scheduler.js";

import { CONFIG_AUTO_DISPOSE } from "./core/constants.js";

import "./core/invariants.js";

import "./core/verdict.js";

import "./core/effect.js";

import { accessor } from "./signals.js";

import { $TRACK } from "./store/store.js";

import "./store/next/store.js";

function mapArray(t, s, i) {
    const e = typeof i?.keyed === "function" ? i.keyed : undefined;
    const r = s.length > 1;
    const n = s;
    const h = {
        Wt: createOwner(),
        xt: 0,
        Kt: t,
        $t: [],
        qt: n,
        zt: [],
        Jt: [],
        Xt: e,
        Yt: e || i?.keyed === false ? [] : undefined,
        Zt: r && i?.keyed !== false ? [] : undefined,
        ts: i?.keyed === false,
        ss: i?.fallback
    };
    const o = computed(updateKeyedMap.bind(h));
    // Untracked reads inside the internal owner resolve via _parentComputed; routing
    // them through node lets store-proxy lookups see pending writes (not stale _value).
        h.Wt.Ot = o;
    o.T &= ~CONFIG_AUTO_DISPOSE;
    return accessor(o);
}

const pureOptions = {
    ownedWrite: true
};

// Exception safety (#2903): a map callback can throw NotReadyError mid-pass
// (async read), and the computed re-runs the whole pass after settle. Every
// pass therefore STAGES its work — new rows are created into temp arrays and
// removals are deferred — and commits to `this` only after every mapper
// succeeded. An aborted pass disposes just the owners it created and leaves
// `_items`/`_mappings`/`_nodes`/`_rows`/`_indexes`/`_len` exactly as they
// were, so the retry diffs against uncorrupted state. Consequence of the
// strong-abort ordering: removed rows now dispose AFTER the pass's new rows
// are created (you cannot destroy state before knowing the pass will land).
function updateKeyedMap() {
    const t = this.Kt() || [], s = t.length;
    t[$TRACK];
 // top level tracking
        runWithOwner(this.Wt, () => {
        let i, e, r, n, 
        // Mappers write freshly-created row/index signals into the STAGE
        // arrays (`rows`/`indexes`), never into `this._rows`/`this._indexes`.
        h = this.Yt ? this.ts ? () => {
            r[e] = signal(t[e], pureOptions);
            return this.qt(accessor(r[e]), e);
        } : () => {
            r[e] = signal(t[e], pureOptions);
            n && (n[e] = signal(e, pureOptions));
            return this.qt(accessor(r[e]), n ? accessor(n[e]) : undefined);
        } : this.Zt ? () => {
            const s = t[e];
            n[e] = signal(e, pureOptions);
            return this.qt(s, accessor(n[e]));
        } : () => {
            const s = t[e];
            return this.qt(s);
        };
        // fast path for empty arrays
                if (s === 0) {
            if (this.xt !== 0) {
                this.Wt.dispose(false);
                this.Jt = [];
                this.$t = [];
                this.zt = [];
                this.xt = 0;
                this.Yt && (this.Yt = []);
                this.Zt && (this.Zt = []);
            }
            if (this.ss && !this.zt[0]) {
                // an aborted fallback attempt leaves an owner without a mapping;
                // dispose it before re-creating
                this.Jt[0]?.dispose();
                this.zt[0] = runWithOwner(this.Jt[0] = createOwner(), this.ss);
            }
        }
        // fast path for new create
         else if (this.xt === 0) {
            const o = new Array(s);
            const c = new Array(s);
            r = this.Yt && new Array(s);
            n = this.Zt && new Array(s);
            try {
                for (e = 0; e < s; e++) o[e] = runWithOwner(c[e] = createOwner(), h);
            } catch (t) {
                for (i = 0; i <= e; i++) c[i]?.dispose();
                throw t;
            }
            // commit
                        if (this.Jt[0]) this.Jt[0].dispose();
 // previous fallback
                        this.zt = o;
            this.Jt = c;
            r && (this.Yt = r);
            n && (this.Zt = n);
            this.$t = t.slice(0);
            this.xt = s;
        } else {
            let o, c, a, f, u, p, w, l, d;
            // skip common prefix
                        for (o = 0, c = Math.min(this.xt, s); o < c && (this.$t[o] === t[o] || this.Yt && compare(this.Xt, this.$t[o], t[o])); o++) {
                if (this.Yt) setSignal(this.Yt[o], t[o]);
            }
            // skip common suffix — counted only; retained entries land in one pass
            // at commit instead of being staged and copied twice
                        for (c = this.xt - 1, a = s - 1; c >= o && a >= o && (this.$t[c] === t[a] || this.Yt && compare(this.Xt, this.$t[c], t[a])); c--, 
            a--) ;
            // no structural change (every position matched in place at equal
            // length — the common post-reconcile shape): keep the same mapped
            // array identity so downstream consumers don't re-run at all
                        if (o === s && this.xt === s) {
                this.$t = t.slice(0);
                return;
            }
            const O = s - this.xt;
            const m = new Array(s);
            const _ = new Array(s);
            r = this.Yt ? new Array(s) : undefined;
            n = this.Zt ? new Array(s) : undefined;
            // 0) prepare a map of all indices in the changed window of newItems,
            // scanning backwards so we encounter them in natural order
                        p = new Map;
            w = new Array(a + 1);
            for (e = a; e >= o; e--) {
                f = t[e];
                u = this.Xt ? this.Xt(f) : f;
                i = p.get(u);
                w[e] = i === undefined ? -1 : i;
                p.set(u, e);
            }
            // 1) step through the old changed window and see if items can be found
            // in the new set; if so, stage them at their new positions; if not,
            // queue them for disposal at commit
                        for (i = o; i <= c; i++) {
                f = this.$t[i];
                u = this.Xt ? this.Xt(f) : f;
                e = p.get(u);
                if (e !== undefined && e !== -1) {
                    m[e] = this.zt[i];
                    _[e] = this.Jt[i];
                    r && (r[e] = this.Yt[i]);
                    n && (n[e] = this.Zt[i]);
                    e = w[e];
                    p.set(u, e);
                } else (l ??= []).push(this.Jt[i]);
            }
            // 2) create new rows into the temp arrays; an abort disposes only these
                        try {
                for (e = o; e <= a; e++) {
                    if (_[e] !== undefined) continue;
                    (d ??= []).push(_[e] = createOwner());
                    m[e] = runWithOwner(_[e], h);
                }
            } catch (t) {
                if (d) for (i = 0; i < d.length; i++) d[i].dispose();
                throw t;
            }
            // 3) commit: land the retained prefix and suffix plus the staged window
            // into the fresh arrays, swap them in (new identity for downstream
            // change propagation), then dispose exited rows
                        for (i = 0; i < o; i++) {
                m[i] = this.zt[i];
                _[i] = this.Jt[i];
                r && (r[i] = this.Yt[i]);
                n && (n[i] = this.Zt[i]);
            }
            for (e = o; e <= a; e++) {
                if (r) setSignal(r[e], t[e]);
                if (n) setSignal(n[e], e);
            }
            for (e = a + 1; e < s; e++) {
                m[e] = this.zt[e - O];
                _[e] = this.Jt[e - O];
                if (r) {
                    r[e] = this.Yt[e - O];
                    setSignal(r[e], t[e]);
                }
                if (n) {
                    n[e] = this.Zt[e - O];
                    if (O !== 0) setSignal(n[e], e);
                }
            }
            this.zt = m;
            this.Jt = _;
            r && (this.Yt = r);
            n && (this.Zt = n);
            this.xt = s;
            // save a copy of the mapped items for the next update
                        this.$t = t.slice(0);
            if (l) for (i = 0; i < l.length; i++) l[i].dispose();
        }
    });
    return this.zt;
}

/**
 * Reactively renders a callback `count` times, reusing previously-rendered
 * entries when only the count changes. Underlying helper for `<Repeat>`.
 *
 * - `options.from` — start index (default `0`); useful for offset/windowed
 *   rendering.
 * - `options.fallback` — accessor returning a value to show when count is `0`.
 *
 * @example
 * ```ts
 * const view = repeat(count, i => `Item ${i}`, { fallback: () => "empty" });
 * ```
 *
 * @description https://docs.solidjs.com/reference/reactive-utilities/repeat
 */ function repeat(t, s, i) {
    const e = s;
    const r = {
        Wt: createOwner(),
        xt: 0,
        es: 0,
        rs: t,
        qt: e,
        Jt: [],
        zt: [],
        ns: i?.from,
        ss: i?.fallback
    };
    const n = computed(updateRepeat.bind(r));
    // Same as mapArray: untracked reads inside the internal owner resolve via
    // _parentComputed, so async reads in row callbacks register with the node
    // (pending tracking + post-settle retry) instead of vanishing.
        r.Wt.Ot = n;
    n.T &= ~CONFIG_AUTO_DISPOSE;
    return accessor(n);
}

// Same staged-commit discipline as `updateKeyedMap` (#2903): the retained
// window overlap is copied into fresh arrays, missing indexes are created
// into them, and `this` is only touched — including disposal of rows leaving
// the window — after every `_map` call succeeded. A NotReadyError mid-pass
// disposes only the owners this pass created and leaves prior state intact
// for the post-settle retry. The overlap math also subsumes the previous
// disjoint-window/front-clear/end-clear/shift special cases.
function updateRepeat() {
    const t = this.rs();
    const s = this.ns?.() || 0;
    runWithOwner(this.Wt, () => {
        if (t === 0) {
            if (this.xt !== 0) {
                this.Wt.dispose(false);
                this.Jt = [];
                this.zt = [];
                this.xt = 0;
                // Reset offset to match the cleared data (#2767, repro 2).
                                this.es = 0;
            }
            if (this.ss && !this.zt[0]) {
                // an aborted fallback attempt leaves an owner without a mapping;
                // dispose it before re-creating
                this.Jt[0]?.dispose();
                this.zt[0] = runWithOwner(this.Jt[0] = createOwner(), this.ss);
            }
            return;
        }
        const i = s + t;
        const e = this.es + this.xt;
        // Retained overlap [keepStart, keepEnd) in global indexes; empty when the
        // windows are disjoint or when coming from empty/fallback.
                const r = Math.max(s, this.es);
        const n = Math.min(i, e);
        const h = new Array(t);
        const o = new Array(t);
        for (let t = r; t < n; t++) {
            o[t - s] = this.Jt[t - this.es];
            h[t - s] = this.zt[t - this.es];
        }
        try {
            for (let t = s; t < i; t++) {
                if (t >= r && t < n) continue;
                h[t - s] = runWithOwner(o[t - s] = createOwner(), () => this.qt(t));
            }
        } catch (t) {
            for (let t = s; t < i; t++) if ((t < r || t >= n) && o[t - s]) o[t - s].dispose();
            throw t;
        }
        // commit: dispose the previous fallback or the rows leaving the window
                if (this.xt === 0) this.Jt[0]?.dispose(); else for (let t = this.es; t < e; t++) if (t < s || t >= i) this.Jt[t - this.es].dispose();
        this.zt = h;
        this.Jt = o;
        this.es = s;
        this.xt = t;
    });
    return this.zt;
}

function compare(t, s, i) {
    return t ? t(s) === t(i) : true;
}

export { mapArray, repeat };