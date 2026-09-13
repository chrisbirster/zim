import { NOT_PENDING, unwrapOverride, STATUS_UNINITIALIZED, REACTIVE_DIRTY, REACTIVE_CHECK, CONFIG_HAS_LANE, OVERRIDE_UNDEFINED, STATUS_PENDING, EFFECT_RENDER, REACTIVE_MANUAL_WRITE, REACTIVE_OPTIMISTIC_DIRTY, EFFECT_USER } from "./constants.js";

import { ext, latestReadActive, currentOptimisticLane, stale } from "./core.js";

import { NotReadyError } from "./error.js";

import "./invariants.js";

import { resolveTransition, getOrCreateLane, hasActiveOverride, activeLanes, signalLanes, findLane, resolveLane, assignOrMergeLane } from "./lanes.js";

import { GlobalQueue, activeTransition, globalQueue, clock, insertSubs, schedule } from "./scheduler.js";

/**
 * The optimistic write engine, moved out of core.ts/scheduler.ts. Everything
 * here serves only optimistic overrides — createOptimistic,
 * createOptimisticStore (and its store-node writes), and the verdict layer's
 * companions (which are optimistic nodes). Modules that can create optimistic
 * state call `installOptimisticEngine()` before creating it; apps that never
 * import one of those APIs never retain any of this.
 *
 * Core call sites fire the hooks behind guards on state only this module can
 * create (`_overrideValue !== undefined`, `currentOptimisticLane !== null`,
 * `_optimisticNodes.length`, `activeLanes.size`), so `!` invocations are safe
 * once the gate holds — the same late-binding contract as verdict.ts.
 */
/** The optimistic half of setSignal, fired when `_overrideValue !== undefined`. */ function optimisticWrite(e, n) {
    const t = e.o?.De !== NOT_PENDING;
    const i = t ? unwrapOverride(e.o?.De) : e.be;
    if (typeof n === "function") n = n(i);
    const u = !!(e.S & STATUS_UNINITIALIZED) || 
    // A dirty node's _value is stale (its queued recompute hasn't run — e.g.
    // a latest() shadow marked by the previous landing's companion snap), so
    // equality against it must not swallow the write. Without this, a sync
    // push returning the shadow to that stale value was dropped, the snap
    // recompute then committed the parent's old value, and the banner showed
    // the previous transition's target (#3041 follow-up).
    !!((e.ie ?? 0) & (REACTIVE_DIRTY | REACTIVE_CHECK)) || !e.Ue || !e.Ue(i, n);
    if (!u) {
        // Same-value write with an active override still entangles the current
        // action's transition — the hold must outlast all overlapping actions.
        if (t) {
            const n = resolveTransition(e);
            if (n && activeTransition !== n) globalQueue.initTransition(n);
        }
        return n;
    }
    if (t) globalQueue.initTransition(resolveTransition(e));
    // No revert target is stashed: while the override is active every reader
    // sees it (A17), so authoritative arrivals commit silently into _value and
    // reverting is just dropping the override — _value is already correct.
     else globalQueue.m.Ke.push(e);
    // Stamp ownership on the node (post-merge, so entangled writers share the
    // joint root). resolveTransition prefers this over the lane's _transition,
    // which a shared subscriber can merge across transactions (#2912).
        ext(e).Nt = activeTransition;
    const l = getOrCreateLane(e);
    ext(e).Be = l;
    e.T |= CONFIG_HAS_LANE;
    // Literal undefined must not land raw: the slot doubles as the optimistic
    // brand, and erasing it makes the write invisible and routes follow-up
    // writes off the optimistic path into permanent commits (#2898).
        ext(e).De = n === undefined ? OVERRIDE_UNDEFINED : n;
    // syncCompanions only pokes _pendingSignal/_latestValueComputed — with
    // neither companion present the call is a guaranteed no-op.
        (e.o?.Ge !== undefined || e.o?.ge !== undefined) && GlobalQueue.Oe !== null && GlobalQueue.Oe(e, n);
    if (e.oe !== undefined) e.Te = clock;
 // §12e: computed-only slot
        insertSubs(e, true);
    schedule();
    return n;
}

/**
 * transitionComplete's override blockage: a settling transition stays open
 * while one of its optimistic nodes holds an active override that is still
 * pending on real (non-affects-sentinel) async.
 */ function transitionBlocked(e) {
    for (let n = 0; n < e.Ke.length; n++) {
        const t = e.Ke[n];
        if (hasActiveOverride(t) && "S" in t && t.S & STATUS_PENDING && t.o?._ instanceof NotReadyError) {
            return true;
        }
    }
    return false;
}

function resolveOptimisticNodes(e) {
    // Settlement writes below (snapCompanionsToState → updatePendingSignal-style
    // notifications) may push fresh optimistic nodes; only this batch settles
    // now, so iterate a fixed window and splice it out at the end.
    const n = e.length;
    for (let t = 0; t < n; t++) {
        const n = e[t];
        if (n.o !== null) n.o.Be = undefined;
        // Revert is a pure drop: there is no revert target to commit —
        // override-covered authoritative values hold in _pendingValue and
        // elevate on their OWN transition's schedule (A18 as re-ruled 2026-07-07).
                if (!(n.S & STATUS_PENDING)) n.S &= ~STATUS_UNINITIALIZED;
        const i = n.o?.De;
        ext(n).De = NOT_PENDING;
        if (i !== NOT_PENDING && n.be !== unwrapOverride(i)) insertSubs(n, true);
        n._e = null;
        if (n.o !== null) n.o.Nt = null;
    }
    // Settlement checkpoint (#2838): companions caught in this batch (or owned
    // by a node in it) re-derive from committed state, so verdicts survive the
    // transition that produced them (A19 — pending is a property of the data).
        for (let t = 0; t < n; t++) {
        const n = e[t];
        if (n.o?.Ge || n.o?.ge) GlobalQueue.un(n);
        const i = n.o?.Et;
        if (i && (i.o?.Ge === n || i.o?.ge === n)) GlobalQueue.un(i);
    }
    e.splice(0, n);
}

function runQueue(e, n) {
    for (let t = 0; t < e.length; t++) e[t](n);
}

/**
 * Run effects from all lanes that are ready (no pending async).
 */ function runLaneEffects(e) {
    for (const n of activeLanes) {
        if (n.an || n.Ae.size > 0) continue;
        const t = n.rn[e - 1];
        if (t.length) {
            n.rn[e - 1] = [];
            runQueue(t, e);
        }
    }
    // Optimistic patch applications ride the same visibility slot as lane
    // effects (in-flight DOM updates); no-op unless patches registered.
        if (e === EFFECT_RENDER) GlobalQueue.ln?.();
}

function cleanupCompletedLanes(e) {
    for (const n of activeLanes) {
        const t = e ? n._e === e : !n._e;
        if (!t) continue;
        if (!n.an) {
            if (n.rn[0].length) runQueue(n.rn[0], EFFECT_RENDER);
            if (n.rn[1].length) runQueue(n.rn[1], EFFECT_USER);
        }
        if (n.tn.o?.Be === n) if (n.tn.o !== null) n.tn.o.Be = undefined;
        n.Ae.clear();
        n.rn[0].length = 0;
        n.rn[1].length = 0;
        activeLanes.delete(n);
        signalLanes.delete(n.tn);
    }
}

/** read()'s per-lane suspension test (pending-throw path, lane context). */ function laneSuspends(e) {
    // Per-lane suspension: only throw if in same lane as pending async
    // AND the node doesn't have an active override (overrides are the visible value,
    // downstream in the lane should read the override, not throw)
    const n = e.o?.Be;
    if (!n) return false;
    return findLane(n) === findLane(currentOptimisticLane) && !hasActiveOverride(e);
}

/**
 * read()'s entanglement gate: a reader recomputing under an optimistic lane
 * that reads a pending mid-transition write sees the committed value; the sub
 * is recorded for replay at commit.
 */ function gatedRead(e, n, t) {
    if (latestReadActive || e.Pe === NOT_PENDING || e.oe || n !== e && !(n.ie & REACTIVE_MANUAL_WRITE)) {
        return false;
    }
    activeTransition.cn.add(t);
    return true;
}

/**
 * read()'s value selection under a lane: return the committed `_value` for
 * optimistic/lane-assigned signals, stale-mode reads, and pending owners.
 */ function laneReadsCommitted(e, n, t) {
    if (e.o?.De !== undefined || !!e.o?.Be || !!(n.S & STATUS_PENDING)) {
        // The committed view hides a staged in-flight value that will promote
        // silently (commitPendingNode never re-notifies). gatedRead records plain
        // signals for replay at commit; async memos are excluded from it by the
        // `_fn` check and reach here instead — a lane-assigned source whose async
        // already settled (laneAsyncSettled keeps _optimisticLane) served its
        // committed value to a reader that never re-ran after the landing, so a
        // pending-gated branch stayed one value behind permanently (#3041
        // follow-up). Record the reader under the same replay contract.
        if (e.Pe !== NOT_PENDING) (activeTransition ?? globalQueue.m).cn.add(t);
        return true;
    }
    if (n === e && stale && t.o?.Et !== e) {
        // The committed view can hide a staged write (a lane member — even just
        // an isPending companion flip — puts the reader "under a lane"). The
        // staged value commits with no re-delivery (commitPendingNode never
        // re-notifies), so record the reader for replay at commit — the same
        // contract gatedRead provides (#2963). gatedRead itself only covers
        // signal reads where the reading computed differs from the source; the
        // owner === el memo/self read lands here instead. With a transaction
        // active the staged value promotes silently at ITS landing, so record
        // into the transaction (#3041 follow-up: a pending-gated branch that
        // first read its async source during the landing flush stayed one value
        // behind permanently); with none, into the ambient batch.
        if (e.Pe !== NOT_PENDING) (activeTransition ?? globalQueue.m).cn.add(t);
        return true;
    }
    return false;
}

/**
 * recompute()'s lane posture: resolve the node's own lane (own=true), or adopt
 * a dependency's optimistic lane (own=false — parent-deeper-than-owned-child
 * can run before its OPT-dirty child propagates).
 */ function recomputeLane(e, n) {
    if (n) {
        const n = resolveLane(e);
        if (!n) return null;
        // Wake-only lane demotion (#3009): a plain write to a latest()-tracked
        // source rides the optimistic channel only to wake verdict companions —
        // its lane is sourced by the companion shadow (_parentSource set) and owns
        // no transaction. When such a node is pulled mid-tick by a latest()/
        // isPending() probe, lane posture would direct-commit _value, leaking the
        // queued write into committed reads before the flush. Return `false` so
        // recompute() runs plain: the value stages and commits with the flush.
        // (el's own override slot excludes companions themselves; a lane merged
        // into a real optimistic lane resolves to a non-companion source.)
                if (!globalQueue.En && !activeTransition && !n._e && n.tn.o?.Et !== undefined && e.o?.De === undefined) {
            if (e.o !== null) e.o.Be = undefined;
            return false;
        }
        return n;
    }
    for (let n = e.nt; n; n = n.it) {
        const t = n.ut;
        if (t.ie & REACTIVE_OPTIMISTIC_DIRTY) {
            const n = resolveLane(t);
            if (n) {
                e.ie |= REACTIVE_OPTIMISTIC_DIRTY;
                assignOrMergeLane(e, n);
                return n;
            }
        }
    }
    return null;
}

/** recompute()'s catch path: track pending async in the current lane. */ function laneAsyncPending(e) {
    const n = findLane(currentOptimisticLane);
    if (n.tn !== e) {
        n.Ae.add(e);
        ext(e).Be = n;
        e.T |= CONFIG_HAS_LANE;
        GlobalQueue.de !== null && GlobalQueue.de(n.tn);
    }
}

/** recompute()'s success path: the node's async settled, clear it from its lane. */ function laneAsyncSettled(e) {
    const n = resolveLane(e);
    if (n) {
        n.Ae.delete(e);
        GlobalQueue.de !== null && GlobalQueue.de(n.tn);
    }
}

function trackOptimisticStore(e) {
    // After initTransition, globalQueue._batch IS activeTransition (same reference)
    globalQueue.m.Tn.add(e);
    schedule();
}

/**
 * Installs the engine's hooks. Idempotent; called by every module that can
 * create optimistic state (verdict.ts at module top level, createOptimistic
 * and createOptimisticStore at first call) BEFORE any optimistic node exists.
 */ function installOptimisticEngine() {
    if (GlobalQueue.kt !== null) return;
    GlobalQueue.kt = optimisticWrite;
    GlobalQueue.dn = resolveOptimisticNodes;
    GlobalQueue.In = transitionBlocked;
    GlobalQueue.Nn = cleanupCompletedLanes;
    GlobalQueue._n = runLaneEffects;
    GlobalQueue.Ft = gatedRead;
    GlobalQueue.ht = laneSuspends;
    GlobalQueue.gt = laneReadsCommitted;
    GlobalQueue.je = recomputeLane;
    GlobalQueue.$e = laneAsyncPending;
    GlobalQueue.ze = laneAsyncSettled;
    GlobalQueue.An = trackOptimisticStore;
}

export { installOptimisticEngine };