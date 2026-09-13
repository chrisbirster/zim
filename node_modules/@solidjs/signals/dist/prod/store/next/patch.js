import { STATUS_ERROR, EFFECT_RENDER } from "../../core/constants.js";

import { ext, runWithOwner, untrack } from "../../core/core.js";

import { StatusError } from "../../core/error.js";

import { GlobalQueue, haltReactivity, setPatchCommitHook, globalQueue, activeTransition } from "../../core/scheduler.js";

import { getOwner, isDisposed } from "../../core/owner.js";

import { $TARGET } from "../store.js";

import { markDescendants, ownedRaw } from "./target.js";

import { installPatchHooks, installRowHooks } from "./patch-hooks.js";

import { emitSetterRowOps } from "./reconcile.js";

import { targetIsPlain, pcOf } from "./store.js";

import { createRenderEffect } from "../../signals.js";

/**
 * PR-A: the patch channel (DESIGN-PATCH-CHANNEL.md).
 *
 * Compiled patch functions — per-record compare-and-write consumers —
 * dispatched by the store's visibility transitions instead of render
 * effects. This module owns registration, the per-flush apply queue
 * (effect-phase timing, §2b), the owned-prev rule (§2c), and dispatch
 * bubbling (§4b). Emission calls live at the four visibility-transition
 * sites (adoption walk, setter notify, fold commit, override lifecycle)
 * and are gated on registration, so unpatched stores pay a null check.
 *
 * Bubbling contract: a targeted nested write reaches ancestor patches as a
 * FORCED re-apply — the third `force` argument makes every compiled compare
 * pass, so the ancestor rewrites its bound fields from its current backing
 * (idempotent, and prev-free: an ancestor's pre-state is not reconstructible
 * after in-place folds). Compiled bodies therefore have the signature
 * `(next, prev, force?)`.
 *
 * Tree-shaking: core never imports this module; stores without patches
 * never schedule the queue.
 */ let queue = null;

let scheduled = false;

function drainApplyQueue() {
    // Settle-time fallback for optimistic emissions (a reverting flush may
    // have no active lanes left to run the lane-slot drain).
    drainOptimistic();
    const e = queue;
    queue = null;
    scheduled = false;
    if (e === null) return;
    // Per-entry isolation: one throwing patch must not abort its siblings
    // (effect parity — each effect isolates its failure). A throwing patch
    // routes through its REGISTERING OWNER's queue chain exactly like a
    // render-effect error (§2b): an Errored boundary above the row collects
    // it (source = the owner, error read via owner._x?._error). Unhandled errors
    // rethrow after the drain so they still surface.
        let t = UNSET;
    for (let n = 0; n < e.length; n++) {
        clearStamp(e[n]);
        const {list: l, prev: o, force: u, t: i} = e[n];
        const r = i !== null ? i.pb ?? i.v : e[n].next;
        t = applyEntries(l, r, o, u, t);
    }
    if (t !== UNSET) {
        // Unhandled patch errors HALT like unhandled effect errors (re-audit 2,
        // P1-4): app state is undefined past an unboundaried throw.
        haltReactivity(t);
        throw t;
    }
}

const UNSET = Symbol();

/** ONE callback/error primitive for every drain (normal, transition-held,
 * optimistic): per-entry isolation — a throwing patch must not abort its
 * siblings (effect parity) — and failures route through the REGISTERING
 * OWNER's queue chain exactly like a render-effect error (§2b): an Errored
 * boundary above the row collects it. Unhandled errors are aggregated by the
 * caller (first one rethrows after its drain completes). */ function applyEntries(e, t, n, l, o) {
    // SNAPSHOT multi-consumer lists (re-audit 5, P1-3): a callback can dispose
    // a sibling's owner, whose unbind SPLICES this same array mid-iteration —
    // index-walking the live array skips the shifted consumer. The dominant
    // single-consumer case pays nothing; unbound entries are marked so a
    // snapshot never applies a consumer severed by an earlier callback.
    const u = e.length > 1 ? e.slice() : e;
    for (let e = 0; e < u.length; e++) {
        const i = u[e];
        if (i.u === true) continue;
        // Disposed owners drop their patches (the row unmounted mid-flush).
                if (i.owner !== null && isDisposed(i.owner)) continue;
        try {
            i.fn(t, n, l);
        } catch (e) {
            let t = false;
            const n = i.owner;
            if (n !== null) {
                // Route through the nearest COMPUTED ancestor (re-audit 2, P1-4):
                // <Errored>.reset() recomputes its sources, and a plain owner (the
                // list driver's listOwner) is not recomputable — the component/memo
                // scope above it is, and recomputing it rebuilds the rows, exactly
                // what reset means for a throwing render effect.
                let l = n;
                while (l !== null && l.oe === undefined) l = l.ke;
                l ??= n;
                const o = new StatusError(l, e);
                ext(l)._ = o;
                l.S = (l.S ?? 0) | STATUS_ERROR;
                t = n.C.notify(l, STATUS_ERROR, STATUS_ERROR, o);
            }
            if (!t && o === UNSET) o = e;
        }
    }
    return o;
}

// Transition-stamped emissions (§2b, "the walk is not the visibility moment
// inside a transition"): entries stash DIRECTLY on their transition
// (`_heldPatches`) and release into the live queue when THAT batch commits
// (patchCommitHook). Reverted transitions never commit — their stash drops
// with the transition object, no revert bookkeeping. The field (rather than
// a WeakMap) keeps the every-flush commit-hook check to one property read;
// the ambient batch never stashes.
let commitHookInstalled = false;

function releaseBatch(e) {
    const t = e.Mt;
    if (t === undefined) return;
    e.Mt = undefined;
    for (let e = 0; e < t.length; e++) pushLive(t[e]);
}

function pushLive(e) {
    if (queue === null) queue = [];
    queue.push(e);
    if (!scheduled) {
        scheduled = true;
        globalQueue.enqueue(EFFECT_RENDER, drainApplyQueue);
    }
}

function push(e) {
    const t = activeTransition;
    if (t !== null) {
        let n = t.Mt;
        if (n === undefined) t.Mt = n = [];
        n.push(e);
        return;
    }
    pushLive(e);
}

/** Self-entry push with SAME-BATCH COALESCING (re-audit 2/3): a record's
 * later non-forced emission into the same container UPDATES the queued
 * entry in place — `next` takes the newest capture (adoption swaps the
 * backing object per emission; dropping the later one applied STALE state),
 * `prev` keeps the batch's earliest (effect semantics: one application per
 * batch spanning the whole window). The entry's consumer list is the live
 * pc.p array, so mid-batch registrants ride the single application. Forced
 * entries and row/slot ops never coalesce; the drain clears the stamps so a
 * quiet record retains nothing from its last batch. */ function pushSelf(e, t) {
    const n = activeTransition;
    let l;
    if (n !== null) {
        let e = n.Mt;
        if (e === undefined) n.Mt = e = [];
        l = e;
    } else {
        if (queue === null) queue = [];
        l = queue;
    }
    if (e.qa === l && e.qe !== null) {
        const n = e.qe;
        n.next = t.next;
        n.list = t.list;
 // pc.p can be re-created if emptied mid-batch
                return;
    }
    e.qa = l;
    e.qe = t;
    t.pc = e;
    l.push(t);
    if (l === queue && !scheduled) {
        scheduled = true;
        globalQueue.enqueue(EFFECT_RENDER, drainApplyQueue);
    }
}

/** Drain-side stamp clear (re-audit 3, P2-6): without it a quiet long-lived
 * record's channel retains its last batch's container array, entry, and both
 * captured backings for the record's lifetime. */ function clearStamp(e) {
    const t = e.pc;
    if (t !== undefined && t.qe === e) {
        t.qa = null;
        t.qe = null;
    }
}

/** Shallow clone for the owned-prev rule (§2c): owned backings fold values
 * INTO the same raw at commit, so a queued prev must be snapshotted. */ function clonePrev(e) {
    return Array.isArray(e) ? e.slice() : {
        ...e
    };
}

/**
 * Emit a record's visibility transition. Callers gate on `hasPatches()` and
 * `t.d` cheaply; this function re-checks and walks ancestors (§4b).
 */ function emitPatch(e, t, n) {
    const l = e.pc !== null ? e.pc.p : null;
    if (l !== null) pushSelf(e.pc, {
        list: l,
        next: t,
        prev: ownedRaw.has(n) ? clonePrev(n) : n,
        force: false,
        t: null
    });
    // Bubbling: ancestors force-re-apply from their LIVE backing, resolved at
    // drain (privatization may clone it between now and then).
        let o = e.u;
    while (o !== null) {
        const e = o.pc !== null ? o.pc.p : null;
        if (e !== null) push({
            list: e,
            next: null,
            prev: null,
            force: true,
            t: o
        });
        o = o.u;
    }
}

/** Emission for sites that already stand at the record with both sides in
 * hand and have already handled ancestors (the adoption walk descends —
 * parents were visited first), so no bubbling walk. */ function emitPatchLocal(e, t, n) {
    const l = e.pc !== null ? e.pc.p : null;
    if (l !== null) pushSelf(e.pc, {
        list: l,
        next: t,
        prev: ownedRaw.has(n) ? clonePrev(n) : n,
        force: false,
        t: null
    });
}

/** Optimistic-channel emission: overrides are visible THIS flush while the
 * transaction is in flight — that is what optimism means. These ride a
 * dedicated queue drained at LANE-EFFECT timing (the regular effect queues
 * are stashed by an in-flight action), with the regular drain as the
 * settle-time fallback. `next === null` = forced re-apply from the live
 * target (the revert shape: committed truth back onto the DOM). */ let optQueue = null;

function drainOptimistic() {
    const e = optQueue;
    optQueue = null;
    if (e === null) return;
    // Same isolation/routing primitive as the normal drain (re-audit blocker
    // 5): one throwing optimistic patch must not abort its siblings, and it
    // must reach the registering owner's Errored boundary.
        let t = UNSET;
    for (let n = 0; n < e.length; n++) {
        clearStamp(e[n]);
        const {list: l, prev: o, force: u, t: i} = e[n];
        const r = i !== null ? i.pb ?? i.v : e[n].next;
        t = applyEntries(l, r, o, u, t);
    }
    if (t !== UNSET) {
        haltReactivity(t);
        throw t;
    }
}

function emitPatchOptimistic(e, t, n) {
    const l = e.pc !== null ? e.pc.p : null;
    if (l === null) return;
    if (optQueue === null) optQueue = [];
    if (t === null) optQueue.push({
        list: l,
        next: null,
        prev: null,
        force: true,
        t: e
    }); else {
        // Same-batch coalescing, optimistic container (re-audit 3): later
        // non-forced emission updates the queued entry's next in place.
        const o = e.pc;
        if (o.qa === optQueue && o.qe !== null) {
            const e = o.qe;
            e.next = t;
            e.list = l;
        } else {
            const e = {
                list: l,
                next: t,
                prev: n,
                force: false,
                t: null
            };
            o.qa = optQueue;
            o.qe = e;
            e.pc = o;
            optQueue.push(e);
        }
    }
    // Backup scheduling: the lane-slot drain covers in-flight application; a
    // stashed regular drain guarantees settle-time application when no lane
    // survives to the final flush (pure reverts).
        if (!scheduled) {
        scheduled = true;
        globalQueue.enqueue(EFFECT_RENDER, drainApplyQueue);
    }
}

/** Row-ops emission at OPTIMISTIC (lane) timing: user drafts on an
 * optimistic family must show structure IN FLIGHT — bypassing the
 * transition stash exactly like emitPatchOptimistic. Two forms:
 * - `ops` given (write site): `nextRows` is the draft's intended visible
 *   list, ops the identity diff against the pre-write optimistic view.
 * - `ops === null` (revert site): RESYNC — the consumer rebuilds retention
 *   by row identity against the live post-revert view, resolved from the
 *   target at drain time (overrides are gone by then, so `pb ?? v` IS the
 *   committed truth). */ function emitRowOpsOptimistic(e, t, n) {
    const l = e.pc !== null ? e.pc.ro : null;
    if (l === null) return;
    if (optQueue === null) optQueue = [];
    optQueue.push({
        list: l.map(e => ({
            owner: e.owner,
            fn: (t, l) => e.fn(t, n)
        })),
        next: t,
        prev: null,
        force: false,
        t: t === null ? e : null
    });
    if (!scheduled) {
        scheduled = true;
        globalQueue.enqueue(EFFECT_RENDER, drainApplyQueue);
    }
}

/**
 * Register a compiled patch on a store record. Multi-consumer (two lists
 * can render one record); owner-scoped for disposal. Returns unbind.
 */
// Global registration count: the cheap gate emission sites check before any
// per-record work (unpatched apps pay one number compare per transition).
let patchCount = 0;

function hasPatches() {
    return patchCount > 0;
}

function registerPatch(e, t) {
    let n = e?.[$TARGET];
    if (n === undefined) throw new Error("registerPatch: not a store record");
    // Chained backings (§7b): register on the ULTIMATE owner — that is where
    // value transitions fold and dispatch; the wrapper's identity is stable
    // and would never fire (see ultimateTarget).
        n = ultimateTarget(n) ?? n;
    if (!commitHookInstalled) {
        commitHookInstalled = true;
        armPatchHooks();
        setPatchCommitHook(releaseBatch);
        GlobalQueue.ln = drainOptimistic;
    }
    const l = {
        fn: t,
        owner: getOwner()
    };
    const o = pcOf(n);
    const u = o.p ??= [];
    u.push(l);
    patchCount++;
    // Bindings are subscriptions for reachability (§6d pruning must descend
    // into bound records).
        markDescendants(n);
    let i = false;
    return () => {
        if (i) return;
        i = true;
        l.u = true;
 // dispatch snapshots skip severed consumers
        // Decrement ONLY on actual removal: a demotion (demoteToEffects) may
        // have already pulled this entry and repaired the count — the splice
        // miss is how this closure learns that.
                const e = u.indexOf(l);
        if (e >= 0) {
            u.splice(e, 1);
            patchCount--;
        }
        if (u.length === 0 && o.p === u) o.p = null;
    };
}

/** Resolve a target through CHAINED backings (§7b) to the ultimate owner.
 * A projection family wrapper's backing IS another store's proxy: value
 * transitions fold on the ULTIMATE target (the wrapper's identity never
 * changes), so patch registration and raw resolution must land there or
 * registered patches never fire (equivalence-matrix finding: projection
 * value ticks froze driver rows while classic effects tracked through). */ function ultimateTarget(e) {
    while (e.ch) {
        const t = (e.pb ?? e.v)?.[$TARGET];
        if (t === undefined) return undefined;
        e = t;
    }
    return e;
}

/** Dual-driver bind probe (compiler runtime contract): when `record` is a
 * patchable store record, returns its CURRENT raw backing (the driver's
 * initial force-apply reads it directly — no proxy traffic, no tracking);
 * returns undefined otherwise (driver falls back to the effect path).
 * Not patchable: non-records, non-proxies, accessor-bearing records
 * (patches read raw — getters need tracked evaluation), broken chains. */ function patchableRaw(e) {
    let t = e?.[$TARGET];
    if (t === undefined || t.px !== e || t.a === true) return undefined;
    t = ultimateTarget(t);
    // SCAN before trusting (re-audit blocker 3): `a` starts false and is only
    // discovered lazily (first draft, deep walks) — admission must run the
    // one-time own-accessor scan itself, or a getter-bearing record takes the
    // patch path and its getter's OUTSIDE dependencies (signals, other
    // records) never re-apply. Sticky `sc` makes this one probe pass per
    // record lifetime.
        if (t === undefined || !targetIsPlain(t)) return undefined;
    return t.pb ?? t.v;
}

/** Accessor demotion (design §5): a record that acquires an accessor after
 * registration stops being patchable — reads must go through tracked
 * evaluation. Clears patches and repairs the global count; callers re-drive
 * the pulled bodies (demoteToEffects). */ function demotePatches(e) {
    if (e.pc === null) return null;
    const t = e.pc.p;
    e.pc.p = null;
    if (t === null) return null;
    patchCount -= t.length;
    // Drain IN PLACE: unbind closures captured this array — a late unbind must
    // miss its indexOf and not double-decrement the repaired count.
        return t.splice(0, t.length);
}

/** The demotion re-drive (re-audit blocker 3): each pulled body becomes the
 * SAME dual-driver effect fallback the web runtime would have chosen had the
 * record carried the accessor at bind — a tracked compute pass (next === prev
 * short-circuits every compare into a pure read THROUGH THE PROXY, so getter
 * dependencies track) plus an untracked force-apply at effect timing.
 *
 * Creation is DEFERRED to the effect phase: the trap that discovers the
 * accessor runs mid-draft, and an effect's initial pass must not read
 * through the proxy inside the write window. The record's own transition
 * for that draft is covered by the new effect's initial force-apply.
 *
 * Known edge (documented): a demoted LIST-ROW body re-drives under its
 * registering owner (the list owner), so per-row severing on removal is
 * lost for demoted rows — the effect lives until the LIST disposes. Rows
 * only demote when user code defines an accessor on a row record at
 * runtime. */ function demoteToEffects(e) {
    const t = demotePatches(e);
    if (t === null || t.length === 0) return;
    const n = e.px;
    globalQueue.enqueue(EFFECT_RENDER, () => {
        for (let e = 0; e < t.length; e++) {
            const l = t[e];
            if (l.owner !== null && isDisposed(l.owner)) continue;
            const o = l.fn;
            runWithOwner(l.owner, () => createRenderEffect(() => {
                o(n, n, false);
            }, () => {
                // Block body: a compiled patch body's return value must not be
                // mistaken for an effect cleanup.
                untrack(() => o(n, undefined, true));
            }));
        }
    });
}

/** Register a structural-ops consumer on a keyed store array (the list
 * container's channel — what `For` consumes through the seam). */ function registerRowOps(e, t) {
    let n = e?.[$TARGET];
    if (n === undefined) throw new Error("registerRowOps: not a store array");
    // Chained backings resolve to the ULTIMATE owner, same as registerPatch
    // (§7b) — the walk/fold emits there (re-audit blocker 4).
        n = ultimateTarget(n) ?? n;
    armRowHooks();
    if (!commitHookInstalled) {
        commitHookInstalled = true;
        armPatchHooks();
        setPatchCommitHook(releaseBatch);
        GlobalQueue.ln = drainOptimistic;
    }
    const l = {
        fn: t,
        owner: getOwner()
    };
    const o = pcOf(n);
    const u = o.ro ??= [];
    u.push(l);
    patchCount++;
    markDescendants(n);
    let i = false;
    return () => {
        if (i) return;
        i = true;
        patchCount--;
        const e = u.indexOf(l);
        if (e >= 0) u.splice(e, 1);
        if (u.length === 0 && o.ro === u) o.ro = null;
    };
}

/** Slot patches (shallow arrays) ride the same apply queue: the walk emits
 * per aligned value-replaced slot; application happens at effect phase under
 * the registration owner's lifetime. */ function emitSlotPatch(e, t, n, l) {
    const o = e.pc !== null ? e.pc.sp : null;
    if (o === null) return;
    push({
        list: o.map(e => ({
            owner: e.owner,
            fn: () => e.fn(t, n, l)
        })),
        next: n,
        prev: l,
        force: false,
        t: null
    });
}

/** Slot patch for shallow arrays: the reconcile walk emits (index, next,
 * prev) for KEY-ALIGNED value-replaced slots (structure rides row ops), and
 * the emission queues through the patch apply queue — effect-phase timing,
 * transition stamping, disposed-owner drop — like every other channel. */ function registerSlotPatchNext(e, t) {
    let n = e?.[$TARGET];
    if (n === undefined) throw new Error("registerSlotPatchNext: not a store array");
    // Chained backings resolve to the ULTIMATE owner, same as registerPatch
    // (§7b) — the walk emits slot ticks there (re-audit blocker 4).
        n = ultimateTarget(n) ?? n;
    armRowHooks();
    if (!commitHookInstalled) {
        commitHookInstalled = true;
        armPatchHooks();
        setPatchCommitHook(releaseBatch);
        GlobalQueue.ln = drainOptimistic;
    }
    // Multi-consumer (external audit): one shallow array can drive several
    // lists — registrations are a list, unbinds splice their own entry.
        const l = pcOf(n);
    const o = {
        fn: t,
        owner: getOwner()
    };
    (l.sp ??= []).push(o);
    markDescendants(n);
    let u = false;
    return () => {
        if (u || l.sp === null) return;
        u = true;
        const e = l.sp.indexOf(o);
        if (e >= 0) l.sp.splice(e, 1);
        if (l.sp.length === 0) l.sp = null;
    };
}

/** Row-ops ride the SAME apply queue/timing as record patches: transition-
 * stamped, applied at effect phase, in emission order (structure before the
 * new rows' own patches can exist; retained rows' value patches commute). */ function emitRowOps(e, t, n) {
    const l = e.pc !== null ? e.pc.ro : null;
    if (l === null) return;
    push({
        list: l.map(e => ({
            owner: e.owner,
            fn: (t, l) => e.fn(t, n)
        })),
        next: t,
        prev: null,
        force: false,
        t: null
    });
}

// Pay-for-use seams: the write paths (store/reconcile/optimistic) emit
// through installed hooks instead of importing this module. Installation is
// LAZY (first registration) rather than a module-scope call — the dist is a
// flat bundle, and a top-level side effect would retain the whole channel in
// every consumer. TWO TIERS so a value-only registration (registerPatch —
// present in ~every bundle under patch-mode default) does not retain the
// list machinery (row-ops emitters + reconcile's diff builders): row hooks
// arm only from the list driver's registrations. Sound because every
// emission site is guarded by the matching pc channel, which only the
// corresponding registration creates. See patch-hooks.ts.
function armPatchHooks() {
    installPatchHooks({
        emitPatch: emitPatch,
        emitPatchLocal: emitPatchLocal,
        emitPatchOptimistic: emitPatchOptimistic,
        hasPatches: hasPatches,
        demoteToEffects: demoteToEffects
    });
}

function armRowHooks() {
    installRowHooks({
        emitRowOps: emitRowOps,
        emitSlotPatch: emitSlotPatch,
        emitSetterRowOps: emitSetterRowOps,
        emitRowOpsOptimistic: emitRowOpsOptimistic
    });
}

export { demotePatches, demoteToEffects, emitPatch, emitPatchLocal, emitPatchOptimistic, emitRowOps, emitRowOpsOptimistic, emitSlotPatch, hasPatches, patchableRaw, registerPatch, registerRowOps, registerSlotPatchNext };