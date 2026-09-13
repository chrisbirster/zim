import "../core/core.js";

import { GlobalQueue } from "../core/scheduler.js";

import "../core/invariants.js";

import "../core/verdict.js";

import "../core/effect.js";

import { storeNextLookup } from "./next/target.js";

/**
 * Brand symbols used internally by the store proxy / projection plumbing.
 * Cross-package wiring; not part of the user-facing API.
 *
 * @internal
 */ const $TRACK = Symbol(0), $TARGET = Symbol(0), $PROXY = Symbol(0), // Node-map slot carrying a record-level `affects()` mark: any read through
// the record witnesses it into the active isPending() probe.
$AFFECTS = Symbol(0);

// Structural field names of store targets (StoreNextTarget aliases these, so
// shared machinery — affects walks, tests — reads targets via the consts).
const STORE_VALUE = "v", STORE_NODE = "n", STORE_HAS = "h";

function lookupTarget(e, t) {
    // Family maps (projections/optimistic) map raw -> target; the global next
    // lookup maps raw -> target too. Proxies resolve through $TARGET directly.
    if (t !== undefined) {
        const o = t.get(e);
        if (o !== undefined) return o[$TARGET] ?? o;
    }
    return storeNextLookup.get(e);
}

// Values marked raw never acquire a proxy identity: wrap() serves them as-is
// everywhere — deep stores hold them as leaf values replaced by reference.
// Once raw, always raw (identity stays single, just unwrapped). Consulted
// only on wrap-creation and ingest paths; reads never touch it.
const rawValues = new WeakSet;

/**
 * Marks a value as raw: no store will ever wrap it — every store presents it
 * as-is, tracked by reference at whatever slot holds it and updated by
 * replacement. Useful for class instances and external objects (editors,
 * scene graphs, Maps) and for record-shaped data updated wholesale. Sticky
 * for the value's lifetime.
 */
// Flipped on the first mark and exported as a LIVE binding: reconcile
// consults it on every recursable pair, and importing the boolean directly
// lets those sites skip even the function call when no shallow store or raw
// mark exists anywhere in the app.
let rawValuesUsed = false;

function isRawValue(e) {
    return rawValuesUsed && rawValues.has(e);
}

function markRawOne(e) {
    if (isWrappable(e)) {
        // A store proxy is already tracked elsewhere: the shallow boundary passes
        // it through by reference (replaced, never edited — same slot semantics
        // as a raw) instead of claiming it raw. The sticky mark is global, so
        // marking a live proxy would make wrap() serve it verbatim through every
        // OTHER store too — downstream deep stores then captured it instead of
        // wrapping it in their own family, and their writes landed in the
        // upstream store's override layer (#2932).
        if (e[$TARGET] !== undefined) return;
        rawValuesUsed = true;
        rawValues.add(e);
    }
}

function markRawIngest(e) {
    if (Array.isArray(e)) {
        for (let t = 0, o = e.length; t < o; t++) markRawOne(e[t]);
    } else {
        for (const t in e) markRawOne(e[t]);
    }
}

const OBJECT_PROTO = Object.prototype;

// Per-prototype memo for the custom-proto branch of isWrappable: the verdict
// is fully determined by the prototype (tag and Node lineage both live on
// the chain), so each class pays the tag call once — not per read.
const wrappableProtos = new WeakMap;

function isWrappable(e) {
    if (e == null || typeof e !== "object" || Object.isFrozen(e)) return false;
    // Plain data and user class instances wrap; platform objects never do
    // (#2952). Native code brand-checks internal slots and throws through a
    // proxy (`Map.prototype.size`, `Date.prototype.getTime`, ...), so
    // collections and other built-ins can't honestly be stores — they get the
    // markRaw-children contract automatically: served raw, mutations land raw,
    // the property holding them still tracks (reassignment notifies). The tag
    // check separates them structurally: user classes stringify as
    // `[object Object]` while every native/host object carries its own brand
    // (`[object Map]`, `[object Date]`, `[object Headers]`, ...), including
    // subclasses, which inherit the tag. getPrototypeOf keeps the hot path
    // (plain and null-proto objects) intrinsic-only — no property lookup.
        const t = Object.getPrototypeOf(e);
    if (t === OBJECT_PROTO || t === null) return true;
    if (Array.isArray(e)) return true;
    let o = wrappableProtos.get(t);
    if (o === undefined) {
        o = Object.prototype.toString.call(e) === "[object Object]" && (
        // Dynamic Node check (kept dynamic so test/SSR overrides of
        // `globalThis.Node` are observed at call time): shimmed DOMs implement
        // nodes as plain user classes, which pass the tag check.
        typeof Node === "undefined" || !(e instanceof Node));
        wrappableProtos.set(t, o);
    }
    return o;
}

let writeOverride = false;

function setWriteOverride(e) {
    writeOverride = e;
}

function getWriteOverride() {
    return writeOverride;
}

// Own enumerable keys including symbols (`Object.keys` drops symbol-keyed props). #2769
function ownEnumerableKeys(e) {
    return Reflect.ownKeys(e).filter(t => Object.prototype.propertyIsEnumerable.call(e, t));
}

/**
 * Scope inheritance for late-created nodes: every live mark whose identity
 * scope contains the owning record's raw — and, for keyed marks, whose key
 * is this property — gets counted on the new node. Inherited marks live
 * exactly as long as the scope's carrier — the release hook below drops
 * them with the entry.
 */ function inheritAffectsMarks(e, t, o) {
    // A live scope exists, so affects.ts already installed the mark engine.
    for (const [r, s] of affectsScopes) {
        if (r.o?.t && s.scope.has(t) && (s.key === undefined || s.key === o)) {
            GlobalQueue.M(e);
            s.inherited.push(e);
        }
    }
}

const affectsScopes = new Map;

/** Next-store node factory for affects carriers/slots: injected by the
 * rewrite module (next targets alias the legacy field names, so everything
 * here EXCEPT node creation works on them structurally). */ let nextAffectsNodeResolver = null;

function setNextAffectsNodeResolver(e) {
    nextAffectsNodeResolver = e;
}

/** Next-store optimistic view for the declaration walk (optimistic rows
 * pushed before the declaration are in motion too — legacy reads its write
 * overlays; next composes armed-node overrides). */ let nextOptimisticViewResolver = null;

function setNextOptimisticViewResolver(e) {
    nextOptimisticViewResolver = e;
}

/** @internal birth inheritance for nodes created inside a live mark window —
 * exported for the rewrite's node factories. */ function affectsScopesLive() {
    return affectsScopes.size > 0;
}

/**
 * Snapshots the identities reachable from `value` into `scope`, reading
 * through write overlays (an optimistic row pushed before the declaration is
 * in motion too). Untracked by construction: walks raw values, never traps.
 * Every LIVE node under each reachable record — property leaves, `$TRACK`,
 * and has-nodes — collects into `found`: those are the graph edges existing
 * readers subscribed through, so the mark registers on them directly and
 * rides the status rails to everything derived. (Nodes born later inherit
 * from the scope in `getNode`.)
 */ function walkAffectsScope(e, t, o, r, 
// Cycle guard, fresh per declaration: the scope itself can't serve — a
// re-declaration on the same carrier unions into a scope that already
// holds the root, and must still descend to pick up records added since.
s) {
    if (!isWrappable(e)) return;
    const f = e[$TARGET] || lookupTarget(e, r);
    // Next targets: walk the pending backing when present (a draft's writes are
    // in motion too) and cover BOTH identities in the scope.
        let n = f ? f.pb ?? f[STORE_VALUE] : e;
    if (s.has(n)) return;
    s.add(n);
    t.scope.add(n);
    if (f && f.pb) t.scope.add(f[STORE_VALUE]);
    // Next optimistic families: enumerate the VISIBLE view (armed-node
    // overrides compose membership/values the raw doesn't carry).
        if (f && f.fam?.opt && nextOptimisticViewResolver) n = nextOptimisticViewResolver(f, n);
    if (f) {
        collectRecordNodes(f[STORE_NODE], o);
        collectRecordNodes(f[STORE_HAS], o);
        // The key-set and deep-witness nodes are record-level channels: a deep()
        // probe reads ONLY these (one pair per record), so a declared affects
        // scope must mark them like any property node.
                if (f.k) o.push(f.k);
        if (f.dk) o.push(f.dk);
        // Carry the effective lookup into untouched descendants (family maps for
        // projections/optimistic stores; the global next lookup otherwise).
                r = f.fam?.map ?? r ?? storeNextLookup;
    }
    // Overlays are gone (next has no layer): raw enumeration; the optimistic
    // view composition above already folded armed-node membership/values in.
        if (Array.isArray(n)) {
        for (let e = 0, f = n.length; e < f; e++) {
            walkAffectsScope(n[e], t, o, r, s);
        }
        const e = Object.getOwnPropertySymbols(n);
        for (let f = 0, c = e.length; f < c; f++) {
            const c = Object.getOwnPropertyDescriptor(n, e[f]);
            if (!c || c.get) continue;
            walkAffectsScope(c.value, t, o, r, s);
        }
    } else {
        const e = Reflect.ownKeys(n);
        for (let f = 0, c = e.length; f < c; f++) {
            const c = Object.getOwnPropertyDescriptor(n, e[f]);
            if (!c || c.get) continue;
            walkAffectsScope(c.value, t, o, r, s);
        }
    }
}

/** All live signal nodes of one record's node map (string + symbol keyed). */ function collectRecordNodes(e, t) {
    if (!e) return;
    for (const o of Object.keys(e)) t.push(e[o]);
    const o = Object.getOwnPropertySymbols(e);
    for (let r = 0, s = o.length; r < s; r++) {
        // Another mark's carrier is its own channel — counting it here would
        // extend that sibling scope's lifetime to this declaration's.
        if (o[r] !== $AFFECTS) t.push(e[o[r]]);
    }
}

/**
 * Witness live mark coverage of a record into the active isPending() probe.
 * Tracked reads don't need this — they go through real signal nodes, which
 * carry marks directly (declaration walk or birth inheritance). This covers
 * UNTRACKED probes reading through records whose nodes never materialized
 * (no observer ever subscribed, so no node exists to carry the mark).
 * Callers guard on `pendingCheckActive`, so plain reads never pay for this.
 *
 * @internal
 */ function witnessAffectsMark(e, t) {
    // Callers guard on `pendingCheckActive`, which only flips inside
    // isPending() — the verdict layer is loaded and its hook installed.
    const o = e[STORE_NODE]?.[$AFFECTS];
    if (o?.o?.t) GlobalQueue.wt(o);
    if (affectsScopes.size) {
        // Chained backings (§7b): a wrapper's STORE_VALUE can be another store's
        // proxy — marks cover by identity of the BASE raw, so resolve the chain
        // and check every identity along it.
        let r = e[STORE_VALUE];
        for (const [e, s] of affectsScopes) {
            if (e !== o && e.o?.t && (s.key === undefined || s.key === t)) {
                let t = r;
                for (;;) {
                    if (s.scope.has(t)) {
                        GlobalQueue.wt(e);
                        break;
                    }
                    const o = t?.[$TARGET];
                    if (o === undefined) break;
                    const r = o.pb ?? o[STORE_VALUE];
                    if (r === t) break;
                    t = r;
                }
            }
        }
    }
}

/**
 * Resolves the store nodes an `affects()` declaration marks: with a `key`,
 * the named slot's leaf node (upserted so the mark has an addressable
 * carrier); without, the record's $AFFECTS carrier plus every LIVE node in
 * its subtree (the edges existing readers subscribed through), with the
 * subtree's identities snapshotted into the mark's scope so nodes created
 * during the window — and untracked probes over captured proxies — resolve
 * against it (#2882).
 *
 * @internal
 */ function getStoreAffectsNodes(e, t) {
    GlobalQueue.p ||= e => {
        const t = affectsScopes.get(e);
        if (!t) return;
        affectsScopes.delete(e);
        for (let e = 0; e < t.inherited.length; e++) GlobalQueue.N(t.inherited[e]);
    };
    if (t === undefined) {
        const t = nextAffectsNodeResolver(e, $AFFECTS);
        let o = affectsScopes.get(t);
        if (!o) affectsScopes.set(t, o = {
            scope: new Set,
            inherited: []
        });
        const r = [ t ];
        walkAffectsScope(e[$PROXY], o, r, e.fam?.map, new Set);
        return r;
    }
    const o = e.n?.[t] ?? nextAffectsNodeResolver(e, t);
    // Keyed marks resolve by identity too (#2904): another store family's
    // proxy can share this record's raw (a derived store swaps its backing to
    // the source's raw when its projection lands), and reads through it never
    // touch this target's node map. Scope is exactly the owning record's raw,
    // narrowed to this key for witness and birth inheritance.
        let r = affectsScopes.get(o);
    if (!r) affectsScopes.set(o, r = {
        scope: new Set,
        inherited: [],
        key: t
    });
    r.scope.add(e[STORE_VALUE]);
    if (e.pb) r.scope.add(e.pb);
    return [ o ];
}

export { $AFFECTS, $PROXY, $TARGET, $TRACK, STORE_HAS, STORE_NODE, STORE_VALUE, affectsScopesLive, getStoreAffectsNodes, getWriteOverride, inheritAffectsMarks, isRawValue, isWrappable, markRawIngest, markRawOne, nextAffectsNodeResolver, nextOptimisticViewResolver, ownEnumerableKeys, rawValuesUsed, setNextAffectsNodeResolver, setNextOptimisticViewResolver, setWriteOverride, witnessAffectsMark };