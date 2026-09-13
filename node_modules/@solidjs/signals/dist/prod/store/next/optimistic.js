import { computed, ext, setSignal, isEqual } from "../../core/core.js";

import { CONFIG_AUTO_DISPOSE, STATUS_PENDING, NOT_PENDING, unwrapOverride, CONFIG_OPTIMISTIC } from "../../core/constants.js";

import { GlobalQueue, insertSubs, schedule, globalQueue } from "../../core/scheduler.js";

import "../../core/invariants.js";

import "../../core/verdict.js";

import "../../core/effect.js";

import { installOptimisticEngine } from "../../core/optimistic.js";

import { $TARGET, markRawIngest, setNextOptimisticViewResolver, isWrappable, rawValuesUsed, isRawValue } from "../store.js";

import { runProjectionComputedNext } from "./projection.js";

import { wrapNext, runAuthoritative, storeSetterNext, hasActiveOverride, unwrapValue, getNode, getHasNode, targetsEqual, getKeySetNode, bumpDeep } from "./store.js";

import { patchHooks, rowHooks } from "./patch-hooks.js";

import { buildIdentityRowOps, sameKey } from "./reconcile.js";

import { setOptHooks } from "./target.js";

/**
 * Store rewrite — optimistic stores (§3/§7, RUL-3): no store-side layer, no
 * backup snapshots. Nodes in an optimistic family are ARMED core signals
 * (`_overrideValue` slot), so every user write rides the engine's
 * optimisticWrite — per-transaction ownership, entanglement, reverts, and
 * flash-at-flush are inherited, not reimplemented. Membership edits live on
 * armed presence nodes (the §6 overlay), so structural optimism reverts with
 * the same per-transaction granularity (FINDING-2's fix by construction).
 *
 * Derived form = an optimistic projection: the derive's recompute and its
 * async commits run under projectionWriteActive (authoritative landings
 * commit silently beneath any active overrides). The transitionBlocked
 * store-half (#2951) is installed here for next-shaped targets, chaining the
 * legacy/engine checks.
 */ let blockedInstalled = false;

function installNextBlockedHalf() {
    if (blockedInstalled) return;
    blockedInstalled = true;
    // Late-bind the optimistic machinery into the plain store/reconcile paths
    // (all call sites are fam?.opt-gated, so this always runs first) and the
    // affects witness's view resolver.
        setOptHooks({
        notifyOptimisticWrites: notifyOptimisticWrites,
        optimisticView: optimisticView,
        applyTentative: applyTentative
    });
    setNextOptimisticViewResolver((e, t) => optimisticView(e, t));
    // Scheduler flush tails call _clearOptimisticStores whenever tracked
    // stores exist; next has no layer to clear — reverts are engine-native —
    // so the hook only empties the batch set.
        if (!GlobalQueue.Bt) {
        GlobalQueue.Bt = e => {
            // Patch channel (revert site): engine-native reverts flip node values
            // back to committed; patched records need a forced DOM re-apply from
            // the post-revert view. Emission only — next keeps no layer to clear.
            for (const t of e) {
                const e = t?.[$TARGET];
                const n = e?.fam?.overlaid;
                if (n !== undefined) {
                    for (const e of n) {
                        if (e.pc !== null && e.pc.p !== null) patchHooks.emitPatchOptimistic(e, null, null);
                        // Row-ops resync (family increment 2): reverts flip node values
                        // back engine-natively; a driven list must rebuild retention by
                        // row identity against the post-revert view (resolved from the
                        // target at drain — overrides are gone by then).
                                                if (e.pc !== null && e.pc.ro !== null) rowHooks.emitRowOpsOptimistic(e, null, null);
                    }
                }
            }
            e.clear();
        };
    }
    const e = GlobalQueue.In;
    GlobalQueue.In = t => {
        for (const e of t.Tn) {
            const t = e?.[$TARGET];
            const n = t?.fam?.node;
            // The hold exists to keep optimistic state alive until the store's own
            // truth lands (#2951). Once the family carries NO live overrides (a
            // landing consumed them, or they never existed), a pending firewall is
            // no reason to park the transaction — blocking then leaks it forever
            // when the in-flight question is never answered (undisposed fixtures).
                        if (n != null && n.S & STATUS_PENDING && familyHasLiveOverrides(t.fam)) return true;
        }
        return e(t);
    };
}

function familyHasLiveOverrides(e) {
    const t = e.overlaid;
    if (t === undefined || t.size === 0) return false;
    for (const e of t) {
        for (const t of [ e.n, e.h ]) {
            if (t === null) continue;
            for (const e of Reflect.ownKeys(t)) {
                const n = t[e];
                if (n.o?.De !== undefined && n.o?.De !== NOT_PENDING) return true;
            }
        }
        if (e.k !== null && e.k.o?.De !== undefined && e.k.o?.De !== NOT_PENDING) return true;
    }
    t.clear();
 // nothing live — drop the bookkeeping
        return false;
}

function createOptimisticStoreNext(e, t, n) {
    // Engine first (armed nodes need optimisticWrite installed before any
    // node exists), then the next-shape hooks.
    installOptimisticEngine();
    installNextBlockedHalf();
    const i = typeof e === "function";
    if (!i && n === undefined) n = t;
    const o = i ? t : e;
    const r = {
        map: new WeakMap,
        node: null,
        shallow: !!n?.shallow,
        opt: true
    };
    const s = wrapNext(o, null, null, r);
    r.px = s;
    if (r.shallow) {
        s[$TARGET].s = true;
        markRawIngest(o);
    }
    if (i) {
        const t = e;
        // Async commits land outside the computed's sync body — re-apply the
        // authoritative-write posture there too. Landings consume the family's
        // tentative overrides (RUL-2: visible landed truth replaces optimism) —
        // both the reconcile-channel commit and per-op post-await draft writes.
                const consume = () => consumeOverridesNext(r);
        const wrapCommit = e => {
            runAuthoritative(e);
            consume();
        };
        let i;
        if (n?.seedLoadingValue) i = {
            loadingValue: undefined
        };
        const o = computed(() => {
            runAuthoritative(() => runProjectionComputedNext(s, t, n?.key === undefined ? "id" : n.key, wrapCommit, consume));
        }, i);
        o.T &= ~CONFIG_AUTO_DISPOSE;
        r.node = o;
    }
    return [ s, e => storeSetterNext(s, e) ];
}

// ---- optimistic-only store machinery (moved from next/store.ts /
// next/reconcile.ts so plain-store bundles tree-shake it) ----
/** Diff the draft against the current OPTIMISTIC VIEW (committed + active
 * overrides — the same view the draft was seeded from) and emit engine writes
 * for exactly the changed keys. Visible-view diffing keeps no-op writes from
 * entangling lanes (RUL-10 / opt R38). */ function notifyOptimisticWrites(e, t) {
    // A bare write while the store's own truth is in flight rides THAT
    // transaction (#2951, legacy parity): entangle the firewall's transition so
    // the override survives until the refetch settles instead of flash-reverting
    // at plain flush end. The blocked-check store-half keeps that transaction
    // from settling while the firewall is pending.
    const n = e.fam?.node;
    if (n?._e) globalQueue.initTransition(n._e);
    const i = e.v;
    // Patch channel (override-application site): the draft IS the intended
    // visible state; prev is the view before these overrides apply. Bypasses
    // the transition stash — optimism is visible in flight.
        if (e.pc !== null && e.pc.p !== null) patchHooks.emitPatchOptimistic(e, t, optimisticView(e, i));
    // Row-ops channel (family increment 2): optimistic STRUCTURE on an array
    // rides node overrides — it never enters the reconcile walk — so a driven
    // list must get its structural ops here, lane-timed. Identity diff of the
    // pre-write optimistic view against the draft; aligned writes emit nothing.
        if (e.pc !== null && e.pc.ro !== null && Array.isArray(t)) {
        const n = optimisticView(e, i);
        if (Array.isArray(n)) {
            const i = buildIdentityRowOps(n, t);
            if (i !== null) rowHooks.emitRowOpsOptimistic(e, t, i);
        }
    }
    const visible = (t, n) => {
        const i = e.n?.[t];
        return i !== undefined && hasActiveOverride(i) ? unwrapOverride(i.o?.De) : n;
    };
    const visiblePresent = t => {
        const n = e.h?.[t];
        return n !== undefined && hasActiveOverride(n) ? !!unwrapOverride(n.o?.De) : t in i;
    };
    let o = false;
    const r = Array.isArray(t);
    for (const n of Reflect.ownKeys(t)) {
        if (r && n === "length") continue;
        const s = unwrapValue(t[n]);
        if (!visiblePresent(n)) {
            // Optimistic add: value node + presence node + membership bump.
            setSignal(getNode(e, n, i[n]), () => s);
            setSignal(getHasNode(e, n, n in i), true);
            o = true;
        } else {
            const t = visible(n, i[n]);
            if (!isEqual(t, s) && !targetsEqual(t, s)) {
                setSignal(getNode(e, n, t), () => s);
                if (r) o = true;
            }
        }
    }
    for (const n of Reflect.ownKeys(i)) {
        if (r && n === "length") continue;
        if (n in t || !visiblePresent(n)) continue;
        // Optimistic delete: node reads undefined, presence flips, membership bumps.
                setSignal(getNode(e, n, i[n]), () => undefined);
        setSignal(getHasNode(e, n, true), false);
        o = true;
    }
    if (r) {
        const n = visible("length", i.length);
        if (n !== t.length) {
            setSignal(getNode(e, "length", n), () => t.length);
            o = true;
        }
    }
    if (o) setSignal(getKeySetNode(e), e => e + 1);
    // Deep-witness: optimistic value writes notify deep() subscribers too
    // (structural ones already ride the key-set bump above).
        bumpDeep(e);
    // Discard the draft — committed raw is untouched (revert target by
    // construction). Register the root store for the scheduler's settle hooks
    // and the target for landing consumption (RUL-2).
        e.pb = null;
    (e.fam.overlaid ??= new Set).add(e);
    GlobalQueue.An?.(e.fam.px ?? e.px);
}

/**
 * Landing consumption (RUL-2): fresh authoritative data supersedes every
 * tentative override in the family. Mirrors legacy clearProjectionOverride —
 * drop the override, clear lane/ownership, notify subscribers whose visible
 * value changes (reversion effects go to regular queues via the projection
 * write posture the caller holds).
 */ function consumeOverridesNext(e) {
    const t = e.overlaid;
    if (t === undefined || t.size === 0) return;
    runAuthoritative(() => {
        for (const e of t) {
            const drop = (e, t) => {
                if (!hasActiveOverride(e)) return;
                const n = unwrapOverride(e.o?.De);
                // Full legacy reset (clearOptimisticOverride parity): the landing is
                // authoritative NOW — fold committed into the node directly instead
                // of riding a transaction's commit (whose queues may be stashed with
                // the transaction parked; the wake would strand until it settles).
                                ext(e).De = NOT_PENDING;
                e.T |= CONFIG_OPTIMISTIC;
                const i = e.o;
                if (i) {
                    i.Nt = null;
                    i.Be = undefined;
                }
                e.Pe = NOT_PENDING;
                e.be = t;
                if (!e.Ue || !e.Ue(n, t)) {
                    insertSubs(e, true);
                    schedule();
                }
            };
            // Landing consumes STRUCTURAL optimism only (legacy layer parity):
            // membership edits, array length, and the value overrides written WITH
            // them (a key carrying an active presence override is an add/delete —
            // classified BEFORE the adoption may have made the key exist in landed
            // data). A pure value override on a key the landing carries stays with
            // its owning transaction (rapid-toggle contract: a live action's edit
            // of an existing entity rides on top of landed truth).
                        const t = Array.isArray(e.v);
            const n = e.h;
            let i = null;
            if (n !== null) {
                for (const e of Reflect.ownKeys(n)) {
                    if (hasActiveOverride(n[e])) (i ??= new Set).add(e);
                }
            }
            const o = e.n;
            if (o !== null) {
                for (const n of Reflect.ownKeys(o)) {
                    const r = i?.has(n) || !(n in e.v) || t && n === "length";
                    if (!r) continue;
                    drop(o[n], t && n === "length" ? e.v.length : e.v[n]);
                }
            }
            if (n !== null) {
                for (const t of Reflect.ownKeys(n)) drop(n[t], t in e.v);
            }
            if (e.k !== null && hasActiveOverride(e.k)) {
                ext(e.k).De = NOT_PENDING;
                e.k.T |= CONFIG_OPTIMISTIC;
                const t = e.k.o;
                if (t) {
                    t.Nt = null;
                    t.Be = undefined;
                }
                insertSubs(e.k, true);
                schedule();
            }
            // Patch channel (override-consumption site): visible truth flipped to
            // committed for the consumed keys — force a re-apply from the live
            // view so the DOM leaves the override state.
                        if (e.pc !== null && e.pc.p !== null) patchHooks.emitPatchOptimistic(e, null, null);
        }
        t.clear();
    });
}

/** Optimistic-view composition for snapshot/deep (O1: snapshot is the CURRENT
 * view, lane values included; a fresh copy per call during pending windows —
 * RUL-12). Returns `src` untouched when no override is active on `t`. */ function optimisticView(e, t) {
    if (e.fam?.opt !== true) return t;
    let n = null;
    const ensure = () => n ??= Array.isArray(t) ? [ ...t ] : {
        ...t
    };
    const i = e.n;
    if (i !== null) {
        for (const e of Reflect.ownKeys(i)) {
            const n = i[e];
            if (!hasActiveOverride(n)) continue;
            const o = unwrapOverride(n.o?.De);
            if (e === "length" && Array.isArray(t)) {
                if (t.length !== o) ensure().length = o;
            } else if (!isEqual(t[e], o)) ensure()[e] = o;
        }
    }
    const o = e.h;
    if (o !== null) {
        for (const e of Reflect.ownKeys(o)) {
            const i = o[e];
            if (!hasActiveOverride(i)) continue;
            const r = !!unwrapOverride(i.o?.De);
            if (!r && e in (n ?? t)) delete ensure()[e];
        }
    }
    return n ?? t;
}

function applyTentative(e, t, n) {
    const i = e.pb ?? e.v;
    const o = optimisticView(e, i);
    const r = e.fam.map;
    const s = Array.isArray(t);
    if (Array.isArray(o) !== s) return;
 // kind change at root: flat overrides below
        const l = [];
    const u = s ? [ ...t ] : shallowWithSymbols(t);
    const match = (e, t) => {
        if (!isWrappable(e) || !isWrappable(t)) return null;
        if (rawValuesUsed && (isRawValue(e) || isRawValue(t))) return null;
        if (Array.isArray(e) !== Array.isArray(t)) return null;
        if (n) {
            const i = n(e);
            const o = n(t);
            // SameValueZero (re-audit 3, P1-3): parity with the plain reconcile
            // channel — NaN keys are self-equal.
                        if (i !== undefined && o !== undefined && !sameKey(i, o)) return null;
        }
        return r.get(unwrapValue(e)) ?? null;
    };
    if (s) {
        const e = o;
        let i = null;
        for (let o = 0; o < t.length; o++) {
            const r = t[o];
            if (!isWrappable(r)) continue;
            let s;
            if (n) {
                const t = n(r);
                if (t !== undefined) {
                    if (i === null) {
                        // Occurrence-aware index queues (re-audit 3, P1-3): parity with
                        // the plain adoption window — duplicate keys match per
                        // occurrence, each view row consumed once.
                        i = new Map;
                        for (let t = 0; t < e.length; t++) {
                            const o = unwrapValue(e[t]);
                            if (isWrappable(o)) {
                                const e = n(o);
                                if (e === undefined) continue;
                                const r = i.get(e);
                                if (r === undefined) i.set(e, t); else if (Array.isArray(r)) r.push(t); else i.set(e, [ r, t ]);
                            }
                        }
                    }
                    const o = i.get(t);
                    if (o === undefined) s = undefined; else if (Array.isArray(o)) {
                        s = unwrapValue(e[o.shift()]);
                        if (o.length === 1) i.set(t, o[0]);
                    } else {
                        s = unwrapValue(e[o]);
                        i.delete(t);
                    }
                } else s = unwrapValue(e[o]);
            } else s = unwrapValue(e[o]);
            const c = match(s, r);
            if (c !== null) {
                // Keep the existing row in the slot (identity preserved); recurse.
                u[o] = unwrapValue(s);
                l.push([ c, r ]);
            }
        }
    } else {
        for (const e of Reflect.ownKeys(t)) {
            const n = unwrapValue(o[e]);
            const i = t[e];
            const r = match(n, i);
            if (r !== null) {
                u[e] = n;
                l.push([ r, i ]);
            }
        }
    }
    // Flat overrides for this level (adds, removals, moved slots, length, leaf
    // values) — preserve any live user draft backing across the call.
        const c = e.pb;
    e.pb = null;
    notifyOptimisticWrites(e, u);
    e.pb = c;
    for (let e = 0; e < l.length; e++) applyTentative(l[e][0], unwrapValue(l[e][1]), n);
}

function shallowWithSymbols(e) {
    const t = {};
    for (const n of Reflect.ownKeys(e)) t[n] = e[n];
    return t;
}

export { consumeOverridesNext, createOptimisticStoreNext, notifyOptimisticWrites, optimisticView };