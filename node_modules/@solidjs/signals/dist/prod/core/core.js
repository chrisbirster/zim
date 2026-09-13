import { handleAsync, clearStatus, parkLoadingWindow, notifyStatus, settleErroredDependents } from "./async.js";

import { EFFECT_TRACKED, REACTIVE_OPTIMISTIC_DIRTY, CONFIG_OPTIMISTIC, NOT_PENDING, STATUS_UNINITIALIZED, STATUS_ERROR, REACTIVE_REASK, REACTIVE_RECOMPUTING_DEPS, CONFIG_SYNC, CONFIG_HAS_LANE, STATUS_PENDING, REACTIVE_MISSED_WAKE, REACTIVE_NONE, REACTIVE_SNAPSHOT_STALE, unwrapOverride, OVERRIDE_UNDEFINED, CONFIG_HAS_COMPANIONS, REACTIVE_LAZY, REACTIVE_DISPOSED, CONFIG_AUTO_DISPOSE, CONFIG_CHILDREN_FORBIDDEN, REACTIVE_CHECK, REACTIVE_DIRTY, REACTIVE_IN_HEAP, REACTIVE_IN_HEAP_HEIGHT, defaultContext, CONFIG_IN_SNAPSHOT_SCOPE, CONFIG_TRANSPARENT, CONFIG_OWNED_WRITE, CONFIG_NO_SNAPSHOT, $REFRESH, REACTIVE_MANUAL_WRITE, CONFIG_FW_CHILDREN, NO_SNAPSHOT, CONFIG_HAS_SNAPSHOT, STORE_SNAPSHOT_PROPS, EFFECT_USER } from "./constants.js";

import { NotReadyError } from "./error.js";

import { trimStaleDeps, link, dormantNodes } from "./graph.js";

import { deleteFromHeap, queueFor, insertIntoHeapHeight, enqueueSub, markNode, markHeap, insertIntoHeap } from "./heap.js";

import { GlobalQueue, activeTransition, globalQueue, clock, insertSubs, queuePendingNode, runInTransition, schedule, notifyEpoch, dirtyQueue, bumpNotifyEpoch, projectionWriteActive, reaskArmed, armReaskClear } from "./scheduler.js";

import "./invariants.js";

import { disposeChildren, markDisposal, inheritId } from "./owner.js";

GlobalQueue.Ce = recompute;

GlobalQueue.Fe = disposeChildren;

let tracking = false;

/** @internal verdict-module glue */ function setPendingCheckActive(e) {
    pendingCheckActive = e;
}

/** @internal verdict-module glue */ function setLatestReadActive(e) {
    latestReadActive = e;
}

/** @internal verdict-module glue */ function setContextInternal(e) {
    context = e;
}

let stale = false;

let pendingCheckActive = false;

let latestReadActive = false;

let context = null;

let currentOptimisticLane = null;

let snapshotCaptureActive = false;

let snapshotSources = null;

function ownerInSnapshotScope(e) {
    while (e) {
        if (e.He) return true;
        e = e.ke;
    }
    return false;
}

function setSnapshotCapture(e) {
    snapshotCaptureActive = e;
    if (e && !snapshotSources) snapshotSources = new Set;
}

function markSnapshotScope(e) {
    e.He = true;
}

function releaseSnapshotScope(e) {
    e.He = false;
    releaseSubtree(e);
    schedule();
}

function releaseSubtree(e) {
    let t = e.ve;
    while (t) {
        if (t.He) {
            t = t.Ve;
            continue;
        }
        if (t.oe) {
            const e = t;
            e.T &= ~CONFIG_IN_SNAPSHOT_SCOPE;
            if (e.ie & REACTIVE_SNAPSHOT_STALE) {
                e.ie &= ~REACTIVE_SNAPSHOT_STALE;
                e.ie |= REACTIVE_DIRTY;
                if (dirtyQueue.xe > e.Le) dirtyQueue.xe = e.Le;
                insertIntoHeap(e, dirtyQueue);
            }
        }
        releaseSubtree(t);
        t = t.Ve;
    }
}

function clearSnapshots() {
    if (snapshotSources) {
        for (const e of snapshotSources) {
            delete e.o?.Qe;
            // StoreNode targets share one pre-initialized hidden class (see
            // createStoreProxy) — assign undefined instead of deleting, and only
            // when present so signal-node sources don't grow the field.
                        if (e[STORE_SNAPSHOT_PROPS] !== undefined) e[STORE_SNAPSHOT_PROPS] = undefined;
        }
        snapshotSources = null;
    }
    snapshotCaptureActive = false;
}

function recompute(e, t = false) {
    // §12d: any recompute can clean a marked subscriber — invalidate skips.
    bumpNotifyEpoch();
    const n = e.Re;
    if (!t) {
        if (e._e && (!n || activeTransition) && activeTransition !== e._e) globalQueue.initTransition(e._e);
        deleteFromHeap(e, queueFor(e));
        if (e.o !== null) e.o.Ee = null;
        // Tracked effects run after finalizePureQueue, so dispose immediately instead of deferring
                if (e._e || n === EFFECT_TRACKED) disposeChildren(e); else if (e.ve !== null || e.he !== null) {
            markDisposal(e);
            const t = ext(e);
            t.We = e.he;
            t.qe = e.ve;
            e.he = null;
            e.ve = null;
            e.Me = 0;
        } else ;
    }
    let i = !!(e.ie & REACTIVE_OPTIMISTIC_DIRTY);
    const u = (e.T & CONFIG_OPTIMISTIC) !== 0 && e.o?.De !== NOT_PENDING && e.o?.De !== undefined;
    const l = !!(e.S & STATUS_UNINITIALIZED);
    // Outgoing error, captured before the compute clears status: if this run
    // recovers to an unchanged value, dependents still holding this object must
    // be swept (settleErroredDependents, #2949).
        const o = e.S & STATUS_ERROR ? e.o?._ : undefined;
    // Re-ask classification lives in the verdict module; capture the flag before
    // the recompute wipes _flags below.
        const s = (e.ie & REACTIVE_REASK) !== 0;
    // Captured before the compute clears it on a sync landing: if that landing
    // is transition-held below, the window must stay open until the hold
    // commits (commitPendingNode) — a closed window plus a held value reads as
    // a pending frame to live observers of the verdict (#2990).
        const a = e.Ie;
    const r = context;
    context = e;
    e.Ye = null;
    e.Ze++;
    e.ie = REACTIVE_RECOMPUTING_DEPS;
    e.Te = clock;
    let c = e.Pe === NOT_PENDING ? e.be : e.Pe;
    let _ = e.Le;
    let f = false;
    let N = tracking;
    let E = currentOptimisticLane;
    tracking = true;
    // A computed's fn establishes its OWN dependencies, so it must never run
    // inside a latest() read window: read() short-circuits through the
    // companion path before dependency linking, so a memo created (eagerly
    // computed) inside latest(fn) came out permanently dependency-less (#2926).
    // latestRead() already suspends the flag for its pull-recomputes; this
    // covers creation-time computes and flushes that run inside the window.
        const I = latestReadActive;
    latestReadActive = false;
    // Lane posture lives with the engine: OPTIMISTIC_DIRTY is only ever set by
    // engine-driven paths, and _optimisticNodes is only pushed by
    // _optimisticWrite, so the hook is installed whenever either gate holds.
        if (i) {
        const t = GlobalQueue.je(e, true);
        if (t) currentOptimisticLane = t;
        // `false` = wake-only lane demotion: recompute plain so a mid-tick
        // latest()/isPending() pull stages instead of direct-committing (#3009).
        // The predicate lives with the engine (recomputeLane).
         else if (t === false) i = false;
    } else if (activeTransition && !t && activeTransition.Ke.length) {
        // Lane adoption: parent-deeper-than-owned-child can run before its OPT-dirty
        // child propagates. Walk deps once and inherit the OPT lane so this node
        // recomputes under the right posture and propagates correctly.
        const t = GlobalQueue.je(e, false);
        if (t) {
            i = true;
            currentOptimisticLane = t;
        }
    }
    const d = n && n !== EFFECT_USER;
    const T = stale;
    if (d) stale = true;
    try {
        if (!false && e.T & CONFIG_SYNC) {
            c = e.oe(c);
            if (e.o !== null) e.o.Ee = null;
            e.Ie = false;
        } else {
            // Snapshot `_inFlight` so we can detect whether `_fn` self-registered an async
            // subscription (e.g. `createProjection` calls `handleAsync` from inside its body
            // with a setter callback). In that case, the outer `handleAsync` call below would
            // clobber the fresh subscription, so we skip it and let the internally-registered
            // iteration drive updates.
            const t = e.o?.Ee;
            const n = e.oe(c);
            const i = typeof n === "object" && n !== null;
            const u = e.o?.Ee !== t;
            c = u || !i ? n : handleAsync(e, n);
            if (!u && !i) {
                if (e.o !== null) e.o.Ee = null;
                // A sync (non-object) return is the first real answer; async-shaped
                // results clear inside handleAsync at their own landing points, and a
                // self-registered flight (inFlightChanged — projections) clears when
                // its internal handleAsync lands.
                                e.Ie = false;
            }
        }
        // On a status-free node clearStatus is a guaranteed no-op: every field
        // its body gates on is either _statusFlags or lives in the cold
        // extension — no extension, no status to clear. (_x from an unrelated
        // installer just makes clearStatus a cheap re-verified no-op.)
                if (e.S !== 0 || e.o !== null) clearStatus(e, t);
        // _optimisticLane is only ever assigned by engine paths (CONFIG_HAS_LANE
        // is their sticky presence mark).
                if (e.T & CONFIG_HAS_LANE && e.o?.Be) GlobalQueue.ze(e);
    } catch (t) {
        const n = t instanceof NotReadyError;
        if (n && e.Ie) {
            // Loading window with an unready sync dependency: register for the
            // source's settle (the settlePendingSource walk runs off
            // _pendingSources + _blocked alone) but take NO read-visible pending
            // status, no downstream propagation, no transition, no lane
            // registration — the committed loading value keeps serving. If the
            // node is currently errored the error stays the answer until this
            // retry can actually run.
            parkLoadingWindow(e, t);
        } else {
            // Track pending async in the lane (not the lane's source — it creates the lane
            // but doesn't belong to it). Set lane BEFORE notifyStatus for downstream propagation.
            if (n && currentOptimisticLane) GlobalQueue.$e(e);
            let i = false;
            if (n) {
                ext(e).fe = true;
                if (GlobalQueue.Je !== null) i = GlobalQueue.Je(e, s);
            }
            notifyStatus(e, n ? STATUS_PENDING : STATUS_ERROR, t, undefined, n ? e.o?.Be : undefined);
            if (i) GlobalQueue.k(e);
        }
    } finally {
        tracking = N;
        latestReadActive = I;
        if (d) stale = T;
        // Consume the missed-wake latch (#3037, set by insertSubs): a dep write
        // landed beneath this pass on a link it had already validated. The wipe
        // below must not key off DIRTY/CHECK — the read-time pull protocol
        // (markNode(c) in read()) marks the running node as part of ordinary
        // bookkeeping, and those marks are correctly discarded here.
                f = (e.ie & REACTIVE_MISSED_WAKE) !== 0;
        e.ie = REACTIVE_NONE | (t ? e.ie & REACTIVE_SNAPSHOT_STALE : 0);
        context = r;
    }
    if (!e.o?._) {
        trimStaleDeps(e);
        const s = u ? unwrapOverride(e.o?.De) : e.Pe === NOT_PENDING ? e.be : e.Pe;
        let r = false;
        try {
            r = !n && l || !e.Ue || !e.Ue(s, c);
        } catch (t) {
            // A throwing user comparator is an error of this node's computation.
            // Route it through the same status path as a compute-phase throw so
            // error boundaries contain it; otherwise it unwinds the scheduler
            // flush, bypassing every boundary and wedging the queue (#2837).
            notifyStatus(e, STATUS_ERROR, t);
        }
        // Effects use `_equals: false` (no per-effect closure). The side effects that
        // the equals closure used to perform — flagging the effect dirty and enqueueing
        // its runner — happen here instead. `!create` matches the previous `initialized`
        // gate: the explicit recompute(node, true) inside effect() does not enqueue, so
        // effect() can call its runner synchronously for the first run.
                if (n && r) {
            e.Xe = !e.o?._;
            // Reuse one bound runner per effect — runEffect no-ops on a stale
            // `_modified`, so re-enqueueing the same function is harmless.
                        if (!t) e.C.enqueue(n, e.et ??= GlobalQueue.tt.bind(null, e));
        }
        if (e.o?._) ; else if (r) {
            const l = u ? e.o?.De : undefined;
            if (t || 
            // Plain sync flush (no transition on either side) commits effect
            // values directly — the pending round-trip (queuePendingNode +
            // commitPendingNodes) exists to sequence transition reveals, and
            // paying it per effect on the plain path is pure overhead.
            n && (activeTransition !== e._e || activeTransition === null) || i) {
                e.be = c;
                // Lane-propagated correction: upstream data is fresh, correct the
                // override unconditionally. The direct _value commit is the lane's
                // own reveal schedule; drop any superseded older hold so its queued
                // commit can't clobber the fresh value.
                                if (u && i) {
                    ext(e).De = c === undefined ? OVERRIDE_UNDEFINED : c;
                    e.Pe = NOT_PENDING;
                }
            } else {
                e.Pe = c;
                // A window landing that gets held re-opens the window until the hold
                // commits — the verdict's held-value branch is window-gated (#2990).
                                if (a) e.Ie = true;
                // Transition-held sync recompute is a write path like setSignal/asyncWrite,
                // so sync derivations of held sources stay visible to isPending()/latest()
                // (#2831). Both companion writes are transition-scoped (optimistic) and
                // auto-revert/re-derive at commit. Skipped for plain flushes where the
                // pending value commits before effects run.
                                if ((activeTransition || e._e) && GlobalQueue.Oe !== null) GlobalQueue.Oe(e, c);
            }
            // insertSubs only walks _subs (no scheduling of its own), so a
            // subscriber-less node has nothing to notify.
                        if (e.u !== null && (!u || i || e.o?.De !== l)) insertSubs(e, i || u);
        } else if (u) {
            // Unchanged value (equals the override) recomputed while the override
            // is active: _value may still be stale, so hold the authoritative value
            // for commit on its own transition's schedule — invisibly (A17/A18).
            if (e.Pe === NOT_PENDING) queuePendingNode(e);
            e.Pe = c;
            if (a) e.Ie = true;
 // see the held branch above (#2990)
                } else if (e.Le != _) {
            for (let t = e.u; t !== null; t = t.ae) {
                insertIntoHeapHeight(t.ce, queueFor(t.ce));
            }
        }
        // Silent recovery: errored → unchanged value fires no notification, but
        // dependents still holding the propagated error consumed their dirty flag
        // in an errored run and may sit on stale commits (#2949). Changed-value
        // recoveries ride insertSubs above; a comparator throw re-errored the node
        // (el._x?._error re-set), so this only runs on a genuinely clean recovery.
                if (o !== undefined && !r && !e.o?._) settleErroredDependents(e, o);
    }
    currentOptimisticLane = E;
    const S = e.Pe !== NOT_PENDING || e.o !== null && (e.o.qe !== null || e.o.We !== null) || (e.S & (STATUS_PENDING | STATUS_UNINITIALIZED)) !== 0;
    // Override-covered holds (hasOverride) always queue: their commit belongs
    // to their own transition's schedule (A18 re-rule) and is unobservable
    // under the override (A17). Revert no longer commits anything, so an
    // unqueued covered hold would leak (INV-7) once the revert clears
    // _transition.
        S && (!t || e.S & STATUS_PENDING) && (!e._e || u) && queuePendingNode(e);
    e._e && n && activeTransition !== e._e && runInTransition(e._e, () => recompute(e));
    // Missed-wake reschedule (see the finally above): values this pass read
    // before the nested commit are stale, so run again now that the heap will
    // accept the node. Equality gates stop same-value landings from cascading,
    // and a re-run only latches again if another nested commit changes a dep
    // beneath it — convergent unless deps genuinely keep changing.
        if (f) {
        enqueueSub(e);
        schedule();
    }
}

function updateIfNecessary(e) {
    // Never re-enter a node that is currently computing: its dep bookkeeping
    // (_depsTail/_depGen) is live, and a nested recompute would corrupt it.
    // A mid-pass mark stays latched for recompute's own tail to reschedule
    // (#3037); readers meanwhile serve the values the pass has so far.
    if (e.ie & REACTIVE_RECOMPUTING_DEPS) return;
    if (e.ie & REACTIVE_CHECK) {
        for (let t = e.nt; t; t = t.it) {
            const n = t.ut;
            const i = n.lt || n;
            if (i.oe) {
                updateIfNecessary(i);
            }
            if (e.ie & REACTIVE_DIRTY) {
                break;
            }
        }
    }
    if (e.ie & (REACTIVE_DIRTY | REACTIVE_OPTIMISTIC_DIRTY) || e.o?._ && e.Te < clock && !e.o?.Ee) {
        recompute(e);
    }
    e.ie = e.ie & (REACTIVE_SNAPSHOT_STALE | REACTIVE_IN_HEAP | REACTIVE_IN_HEAP_HEIGHT);
}

function computed(e, t) {
    const n = t?.transparent ?? false;
    // `in` (not `!== undefined`): an explicit `loadingValue: undefined` on a
    // `T | undefined` node is a real commit #0. The typeof guard tolerates
    // non-object option values that older call shapes force through `as any`.
        const i = t !== null && typeof t === "object" && "loadingValue" in t;
    const u = {
        id: inheritId(t, n, context),
        T: (n ? CONFIG_TRANSPARENT : 0) | (t?.ownedWrite ? CONFIG_OWNED_WRITE : 0) | (!context || t?.lazy ? CONFIG_AUTO_DISPOSE : 0) | (t?.sync ? CONFIG_SYNC : 0) | (t?.H ? CONFIG_NO_SNAPSHOT : 0) | (snapshotCaptureActive && ownerInSnapshotScope(context) ? CONFIG_IN_SNAPSHOT_SCOPE : 0),
        Ue: t?.equals != null ? t.equals : isEqual,
        he: null,
        C: context?.C ?? globalQueue,
        we: context?.we ?? defaultContext,
        Me: 0,
        oe: e,
        be: i ? t.loadingValue : undefined,
        Le: 0,
        ot: undefined,
        st: null,
        nt: null,
        Ye: null,
        Ze: 0,
        u: null,
        rt: null,
        ke: context,
        Ve: null,
        ct: null,
        ve: null,
        ie: t?.lazy ? REACTIVE_LAZY : REACTIVE_NONE,
        // A loadingValue node is born committed: commit #0 is already in _value.
        S: i ? 0 : STATUS_UNINITIALIZED,
        Te: clock,
        Pe: NOT_PENDING,
        _e: null,
        _t: -1,
        Ie: i,
        // Cold machinery (async/transition/optimistic/verdict slots) lives one
        // hop away in the lazily-allocated extension — the core literal MUST
        // stay under V8's in-object boundary (§12: past ~39 fields every
        // allocation spills to a backing store and creation cost ~4x's).
        o: null
    };
    if (t?.unobserved) ext(u).ft = t.unobserved;
    setupComputedNode(u, t);
    return u;
}

/** Lazily allocate a node's cold extension (ONE shape for signals and
 * computeds — `_x` access stays monomorphic). Installers write through
 * this; hot paths read `el._x?._field` gated by the _config presence bits.
 * Never call ext() just to store a field's default. */ function ext(e) {
    return e.o ??= {
        De: undefined,
        Nt: undefined,
        Be: undefined,
        Ge: undefined,
        ge: undefined,
        Et: undefined,
        t: 0,
        Ee: null,
        _: undefined,
        fe: undefined,
        le: undefined,
        h: undefined,
        pe: false,
        i: null,
        ft: undefined,
        Qe: undefined,
        We: null,
        qe: null,
        It: undefined
    };
}

/**
 * Build an Effect node with all effect-specific fields baked into a single object literal,
 * so V8 sees the full hidden class shape at construction time. Effects always run in lazy
 * mode (recompute is called explicitly by `effect()`), so we hardcode the lazy bits and skip
 * the auto-dispose CONFIG bit (effect() previously cleared it post-construction).
 */ function createEffectNode(e, t, n, i, u) {
    const l = u?.transparent ?? false;
    const o = {
        id: inheritId(u, l, context),
        T: (l ? CONFIG_TRANSPARENT : 0) | (u?.ownedWrite ? CONFIG_OWNED_WRITE : 0) | (u?.sync ? CONFIG_SYNC : 0) | (snapshotCaptureActive && ownerInSnapshotScope(context) ? CONFIG_IN_SNAPSHOT_SCOPE : 0),
        Ue: false,
        he: null,
        C: context?.C ?? globalQueue,
        we: context?.we ?? defaultContext,
        Me: 0,
        oe: e,
        be: undefined,
        Le: 0,
        ot: undefined,
        st: null,
        nt: null,
        Ye: null,
        Ze: 0,
        u: null,
        rt: null,
        ke: context,
        Ve: null,
        ct: null,
        ve: null,
        ie: REACTIVE_LAZY,
        S: STATUS_UNINITIALIZED,
        Te: clock,
        Pe: NOT_PENDING,
        _e: null,
        _t: -1,
        Ie: false,
        Xe: false,
        dt: undefined,
        Tt: t,
        St: n,
        At: undefined,
        Re: i,
        o: null
    };
    // Effects dispatch status through the SHARED notifier (statusNotifierOf,
    // keyed off _type) — storing it per node forced a full NodeExtension
    // allocation on EVERY effect at creation (an alloc + 19 field stores,
    // +23% effect creation, caught by the creation benches). Only genuinely
    // per-node channels (boundaries) live on _x.
        if (u?.unobserved) ext(o).ft = u.unobserved;
    setupComputedNode(o, lazyOptions);
    return o;
}

/**
 * The shared status notifier for effect nodes, installed once by effect.ts
 * at module evaluation (`this`-dispatched — one function serves every
 * effect, so nodes never store it). Boundary computeds keep their own
 * per-node channel on `_x._notifyStatus`, which takes precedence.
 */ let effectStatusNotify = null;

function setEffectStatusNotify(e) {
    effectStatusNotify = e;
}

/** Resolve a node's status notifier: an own `_x` channel (boundaries) wins;
 * effect nodes (`_type` — EFFECT_PURE is 0, and only effect literals carry
 * the field) fall back to the shared notifier. Presence doubles as the
 * "display consumer" membership test in the status walks, exactly as the
 * per-node field did when every effect carried one. */ function statusNotifierOf(e) {
    const t = e.o;
    const n = t !== null && t !== undefined ? t.h : undefined;
    if (n !== undefined) return n;
    return e.Re ? effectStatusNotify ?? undefined : undefined;
}

const lazyOptions = {
    lazy: true
};

function setupComputedNode(e, t) {
    e.st = e;
    const n = context?.Ct ? context.Ot : context;
    if (context) {
        const t = context.ve;
        if (t === null) {
            context.ve = e;
        } else {
            e.Ve = t;
            t.ct = e;
            context.ve = e;
        }
    }
    if (n) e.Le = n.Le + 1;
    if (GlobalQueue.Rt !== null) GlobalQueue.Rt(e);
    !t?.lazy && recompute(e, true);
    if (snapshotCaptureActive && !t?.lazy) {
        if (!(e.S & STATUS_PENDING) && !(e.T & CONFIG_NO_SNAPSHOT)) {
            ext(e).Qe = e.be === undefined ? NO_SNAPSHOT : e.be;
            e.T |= CONFIG_HAS_SNAPSHOT;
            snapshotSources.add(e);
        }
    }
}

function signal(e, t, n = null) {
    const i = {
        Ue: t?.equals != null ? t.equals : isEqual,
        T: (t?.ownedWrite ? CONFIG_OWNED_WRITE : 0) | (t?.H ? CONFIG_NO_SNAPSHOT : 0),
        be: e,
        u: null,
        rt: null,
        Te: clock,
        lt: n,
        Se: n?.o?.i || null,
        Pe: NOT_PENDING,
        // Signal-literal diet (§12e): NO _time/_fn/_statusFlags slots. Stores
        // materialize one signal per touched leaf, so signal bytes are store
        // bytes. _time is write-only on signals (every read site is computed-
        // typed error-retry gating); _fn/_statusFlags read falsy-identically as
        // missing properties on the shared paths (undefined masks to 0).
        _e: null,
        _t: -1,
        o: null
    };
    if (t?.unobserved) ext(i).ft = t.unobserved;
    if (n) {
        ext(n).i = i;
        n.T |= CONFIG_FW_CHILDREN;
    }
    if (snapshotCaptureActive && !(i.T & CONFIG_NO_SNAPSHOT) && !((n?.S ?? 0) & STATUS_PENDING)) {
        ext(i).Qe = e === undefined ? NO_SNAPSHOT : e;
        i.T |= CONFIG_HAS_SNAPSHOT;
        snapshotSources.add(i);
    }
    return i;
}

function optimisticSignal(e, t) {
    const n = signal(e, t);
    ext(n).De = NOT_PENDING;
    n.T |= CONFIG_OPTIMISTIC;
    return n;
}

function optimisticComputed(e, t) {
    const n = computed(e, t);
    ext(n).De = NOT_PENDING;
    n.T |= CONFIG_OPTIMISTIC;
    return n;
}

function isEqual(e, t) {
    return e === t;
}

/**
 * Runs `fn` outside of any reactive tracking — reads inside `fn` will not
 * subscribe the current scope. Returns whatever `fn` returns.
 *
 * Use `untrack` inside a memo or effect when you need to read a signal once
 * without making the surrounding computation depend on its future changes.
 *
 * Pass a `strictReadLabel` string to enable a dev-mode warning: any reactive
 * read inside `fn` that isn't inside a nested tracking scope will log a
 * warning naming the label.
 *
 * @example
 * ```ts
 * createEffect(
 *   () => trigger(),                 // tracks `trigger` only
 *   () => {
 *     const snapshot = untrack(() => state); // read once, untracked
 *     log(snapshot);
 *   }
 * );
 * ```
 */ function untrack(e, t) {
    if (GlobalQueue.Gt === null && !tracking && true) return e();
    const n = tracking;
    tracking = false;
    try {
        if (GlobalQueue.Gt !== null) return GlobalQueue.Gt(e);
        return e();
    } finally {
        tracking = n;
    }
}

/**
 * Bring a computed to a readable state: lazy/disposed nodes are (re)computed;
 * an isPending() probe (`refresh`) additionally pulls the node fully up to
 * date so its status flags reflect the current graph.
 */ function prepareComputed(e, t) {
    if (e.ie & REACTIVE_LAZY) {
        e.ie &= ~REACTIVE_LAZY;
        recompute(e, true);
    } else if (e.ie & REACTIVE_DISPOSED) {
        // Two disposal lifecycles share the flag (#3024). Observation-lifecycle
        // nodes (CONFIG_AUTO_DISPOSE) are dormant — torn down by unobserved()
        // when the last subscriber left — and reads reawaken them; that is the
        // pay-for-use contract. Owner-lifecycle nodes are dead: recomputing would
        // re-run user code in a torn-down tree (and discard manual writes on
        // derived-writable signals), so reads return the last committed value.
        if (e.T & CONFIG_AUTO_DISPOSE) recompute(e, true);
    } else if (t) {
        updateIfNecessary(e);
    }
}

/**
 * Sentinel returned by readNodeFast when the plain-signal fast path does not
 * apply and the caller must fall back to the full read().
 */ const READ_SLOW = Symbol("read-slow");

/**
 * read()'s plain-signal fast path as a standalone entry for hot callers
 * (store traps). Safe to substitute for read() only because the bail
 * conditions mirror read()'s prelude and fast-path guard exactly: the
 * latestRead and pendingCheck windows run side-effectful hooks before the
 * fast path, `_fn` nodes need prepareComputed, and firewall / override /
 * snapshot / transition / lane / dev-strictRead state all take the full
 * resolution. Anything slow returns READ_SLOW; the caller then calls read().
 */ function readNodeFast(e) {
    if (latestReadActive || pendingCheckActive || e.oe || e.lt || e.o?.De !== undefined || e.o?.Qe !== undefined || activeTransition !== null || currentOptimisticLane !== null || snapshotCaptureActive || false) return READ_SLOW;
    let t = context;
    if (t?.Ct) t = t.Ot;
    if (t && tracking) link(e, t);
    // Children-forbidden readers (createTrackedEffect / onSettled callbacks) get
    // committed visibility: like the effect half of createEffect and event
    // handlers, effect-phase code never observes its own unsettled write — the
    // write lands in the same flush's continuation (#3006).
        return !t || e.Pe === NOT_PENDING || t.T & CONFIG_CHILDREN_FORBIDDEN ? e.be : e.Pe;
}

function read(e) {
    // Handle latest() mode: read from _latestValueComputed
    // Checked before isPending so that isPending(() => latest(x)) checks
    // the _pendingSignal of _latestValueComputed (async in flight) rather
    // than the original node (which stays "pending" while held in a transition).
    if (latestReadActive) return GlobalQueue.Pt(e);
    let t = context;
    if (t?.Ct) t = t.Ot;
    const n = e;
    const i = e.lt;
    const u = i || e;
    // Handle isPending() mode: collect pending state while preserving normal read semantics.
    // Probe mode is suspended while preparing the node so nested reads during a
    // recompute don't collect into the probe.
        if (pendingCheckActive) {
        GlobalQueue.Dt(e, t, u, i);
    } else if (typeof n.oe === "function") {
        prepareComputed(e, false);
    }
    if (!n.oe && u === e && e.o?.De === undefined && e.o?.Qe === undefined && activeTransition === null && currentOptimisticLane === null && !snapshotCaptureActive && true) {
        if (t && tracking) link(e, t);
        // Committed visibility for children-forbidden readers — see readNodeFast.
                return !t || e.Pe === NOT_PENDING || t.T & CONFIG_CHILDREN_FORBIDDEN ? e.be : e.Pe;
    }
    if (t && tracking) {
        link(e, t, pendingCheckActive);
        if (u.oe) {
            const n = queueFor(e);
            if (u.Le >= n.xe) {
                markNode(t);
                markHeap(n);
                updateIfNecessary(u);
            }
            const i = u.Le;
            // parent check is shallow, might need to be recursive
                        if (i >= t.Le && e.ke !== t) {
                t.Le = i + 1;
            }
        }
    }
    if (u.S & STATUS_PENDING) {
        if (t && !(stale && u._e && activeTransition !== u._e)) {
            // Per-lane suspension lives with the engine (a non-null lane implies it
            // is installed): under a lane, only same-lane pending async without an
            // active override throws.
            if (currentOptimisticLane === null || GlobalQueue.ht(u)) {
                if (!tracking && e !== t) link(e, t);
                throw u.o?._;
            }
        } else if (t && u.S & STATUS_UNINITIALIZED) {
            // A stale (render) reader of a node held pending in ANOTHER transition
            // normally keeps showing the node's committed value instead of
            // entangling the two transactions — but an uninitialized node has no
            // committed value to show. Suspend on it (firewall-backed store reads
            // always took this branch; plain memos now do too): the reader
            // registers as a reporter of that source, and its pending-node stamp
            // ties it to the active transaction, so the two transactions merge
            // when the source settles. Falling through served `undefined` as if
            // settled and stranded the reader outside both transactions, so it
            // never re-ran when either landed (#3043 port).
            if (!tracking && e !== t) link(e, t);
            throw u.o?._;
        } else if (!t && u.S & STATUS_UNINITIALIZED) {
            throw u.o?._;
        }
    }
    // `owner` is the computed itself, or the firewall behind a store node —
    // firewall-backed reads follow the same rules (memo parity, #2897 ruling):
    // an errored derive throws for every late reader instead of silently
    // serving node values (the seed, or last-good data after a failed refetch).
        if (u.oe && u.S & STATUS_ERROR) {
        // Only a genuine reactive re-read may retry an errored async source:
        // - tracking: owned/tracked scope only (never events / `untrack` / effect side-effect phase)
        // - !pendingCheckActive: an `isPending` probe observes the error, never refetches
        // - owner._time < clock: only on a later cycle than the one the error was found
        if (tracking && !pendingCheckActive && u.Te < clock) {
            recompute(u);
            return read(e);
        } else throw u.o?._;
    }
    if (snapshotCaptureActive && t && t.T & CONFIG_IN_SNAPSHOT_SCOPE) {
        const n = e.o?.Qe;
        if (n !== undefined) {
            const i = n === NO_SNAPSHOT ? undefined : n;
            const u = e.Pe !== NOT_PENDING ? e.Pe : e.be;
            if (u !== i) t.ie |= REACTIVE_SNAPSHOT_STALE;
            return i;
        }
    }
    if (e.o?.De !== undefined && e.o?.De !== NOT_PENDING) {
        // A17: the override IS the value for every reader.
        return unwrapOverride(e.o?.De);
    }
    // Entanglement gate: a reader recomputing under an optimistic lane that reads
    // a pending mid-transition write sees the committed value. Projection-store
    // manual writes use the firewall's manual-write flag to opt into this path.
    // Async drivers are not under an optimistic lane and so bypass this, reading
    // _pendingValue for correct fetching. The sub is recorded for replay at commit
    // so it re-runs with the new committed view. (Gate details live with the
    // engine — a non-null lane implies it is installed.)
        if (currentOptimisticLane !== null && activeTransition !== null && t !== null && GlobalQueue.Ft(e, u, t)) {
        return e.be;
    }
    // In optimistic lane context, return _value for optimistic/lane-assigned signals
    // and for regular signals in stale mode (render effects). Non-stale readers (user
    // effects) see _pendingValue so that latest() and direct reads stay consistent.
    // (The lane-context clause lives with the engine.) Children-forbidden readers
    // (createTrackedEffect / onSettled callbacks) get committed visibility — see
    // readNodeFast (#3006).
        const l = !t || currentOptimisticLane !== null && GlobalQueue.gt(e, u, t) || e.Pe === NOT_PENDING || t.T & CONFIG_CHILDREN_FORBIDDEN || stale && e._e && activeTransition !== e._e ? e.be : e.Pe;
    // Record that this isPending() probe observed the fresh pending value, so
    // the probe doesn't pair "pending" with the new value (#2831).
        if (pendingCheckActive) GlobalQueue.Ht(e, l);
    if (!t && u === e && typeof n.oe === "function" && e.T & CONFIG_AUTO_DISPOSE && !(u.S & STATUS_PENDING) && !e.u) {
        // Deferred, not inline (#3078): an inline unobserved() here made untracked
        // reads destructive — dispose on this read, full revival recompute on the
        // next — so consecutive reads could answer differently with no write in
        // between (the revival samples the ambient transition/lane context).
        // The sweep at flush finalization re-validates and reclaims; schedule()
        // guarantees that flush happens even if nothing else is queued.
        dormantNodes.add(e);
        schedule();
    }
    return l;
}

function setSignal(e, t) {
    if (e._e && activeTransition !== e._e) globalQueue.initTransition(e._e);
    // The optimistic write path lives with the engine: only optimisticSignal /
    // optimisticComputed callers and optimistic store nodes carry an
    // _overrideValue slot (flagged by CONFIG_OPTIMISTIC — a masked read of the
    // always-present config instead of a missing-property probe), and every
    // module that installs one installs the engine first.
        if (e.T & CONFIG_OPTIMISTIC && !projectionWriteActive) return GlobalQueue.kt(e, t);
    const n = e.Pe === NOT_PENDING ? e.be : e.Pe;
    if (typeof t === "function") t = t(n);
    // Uninitialized check first: the first commit has no previous value, so the
    // user comparator must not run against `undefined` (matches recompute).
        const i = !!(e.S & STATUS_UNINITIALIZED) || !e.Ue || !e.Ue(n, t);
    if (!i) return t;
    const u = e.Pe !== NOT_PENDING;
    if (!u) queuePendingNode(e);
    e.Pe = t;
    // syncCompanions only pokes _pendingSignal/_latestValueComputed — with
    // neither companion present the call is a guaranteed no-op (companions are
    // only ever created, never removed, and creating one installs the hook and
    // sets CONFIG_HAS_COMPANIONS — one masked read replaces two optional-field
    // probes on every write).
        e.T & CONFIG_HAS_COMPANIONS && GlobalQueue.Oe !== null && GlobalQueue.Oe(e, t);
    // _time is a computed-only slot (§12e): writing it on a signal would fork
    // the lean shape. Every read site is computed-typed.
        if (e.oe !== undefined) e.Te = clock;
    // Staged-rewrite fast path (§12d): a re-write to a node whose subscribers
    // were already walked — and where nothing has recomputed or linked since
    // (epoch) — re-stages the value and stops. The walk is idempotent (subs
    // marked, heap entries flag-guarded, effects queued once); lane and reask
    // contexts change what a walk MEANS, so they always walk.
        if (u && e._t === notifyEpoch && currentOptimisticLane === null && !reaskArmed) return t;
    insertSubs(e);
    schedule();
    return t;
}

/**
 * Suppresses automatic recomputation of `el` until the scheduler drains. Used
 * when a manual write should win over dependency changes queued in the same
 * tick. The MANUAL_WRITE flag is cleared by the pending-node drain; projection
 * computeds don't commit values, but they still need the same end-of-tick
 * cleanup point.
 */ function suppressComputedRecompute(e) {
    deleteFromHeap(e, queueFor(e));
    if (!(e.ie & REACTIVE_MANUAL_WRITE) && e.Pe === NOT_PENDING) {
        queuePendingNode(e);
        schedule();
    }
    e.ie = e.ie & -4 | REACTIVE_MANUAL_WRITE;
    e.vt = clock;
}

/**
 * User-facing setter for the memo form of `createSignal(fn)`. Behaves like
 * `setSignal`, but also cancels any pending recompute of the memo so the
 * manual value wins over a value that would otherwise be produced by an
 * upstream change in the same tick.
 */ function setMemo(e, t) {
    const n = setSignal(e, t);
    suppressComputedRecompute(e);
    return n;
}

/**
 * Executes `fn` with the given `owner` set as the current owner. Any reactive
 * primitives (`createSignal`, `createMemo`, `createEffect`, `onCleanup`,
 * `cleanup`, etc.) created inside `fn` are attached to that owner, so they
 * are disposed when the owner is disposed.
 *
 * The classic pattern: capture the current owner with `getOwner()` inside a
 * component, then re-enter it from a callback (event handler, async resolve,
 * setTimeout) so disposables created in the callback get cleaned up with the
 * component.
 *
 * @example
 * ```ts
 * function delayed<T>(ms: number, fn: () => T) {
 *   const owner = getOwner();
 *   setTimeout(() => runWithOwner(owner, fn), ms);
 * }
 * ```
 */ function runWithOwner(e, t) {
    const n = context;
    const i = tracking;
    context = e;
    tracking = false;
    try {
        return t();
    } finally {
        context = n;
        tracking = i;
    }
}

function staleValues(e, t = true) {
    const n = stale;
    stale = t;
    try {
        return e();
    } finally {
        stale = n;
    }
}

/**
 * Invalidates one reactive source, forcing it to re-execute even if its inputs
 * haven't changed.
 *
 * Pass either a Solid-created accessor or a projected store created from
 * `createStore(fn, ...)` / `createProjection(...)`. `refresh()` is a
 * write-like invalidation operation: it does not read the target's value, and
 * refreshing a plain signal accessor is a no-op.
 *
 * Use it to invalidate cached async values (e.g. force a re-fetch) without
 * tearing the consumer down.
 *
 * @example
 * ```ts
 * const user = createMemo(async () => fetch(`/users/${id()}`).then(r => r.json()));
 *
 * // Re-fetch on demand
 * <button onClick={() => refresh(user)}>Reload</button>
 * ```
 */ function refresh(e) {
    const t = e?.[$REFRESH];
    if (!t) {
        return;
    }
    if (typeof t.oe === "function" && !(t.ie & REACTIVE_DISPOSED)) {
        if (t.ie & REACTIVE_MANUAL_WRITE) {
            // A manual write in the CURRENT tick wins over the refresh (#2692).
            // A mask stamped in an earlier tick only survives because a
            // transaction (action) is holding the pending drain open; there the
            // refresh is a later, explicit re-ask and lifts the mask — otherwise
            // any setStore early in an action silently swallows every refresh()
            // for the rest of the transaction (#3026).
            if (t.vt === clock) return;
            t.ie &= ~REACTIVE_MANUAL_WRITE;
            // No REASK below: the batch carries a manual value change, so the
            // recompute is not a quiet re-ask of an unchanged question.
                }
        // A refresh with no value-change dirt already queued is a re-ask of the
        // same question: mark it so the recompute classifies any resulting
        // pending window as quiet (not pending). If the node is already dirty
        // from a real input change, the question changed — don't mark.
        // REACTIVE_IN_HEAP counts as dirt: insertSubs schedules subscribers by
        // heap insertion alone (no DIRTY/CHECK flag), so a same-batch value
        // change followed by refresh() must not be laundered into a quiet re-ask.
         else if (!(t.ie & (REACTIVE_DIRTY | REACTIVE_CHECK | REACTIVE_IN_HEAP))) {
            t.ie |= REACTIVE_REASK;
            armReaskClear();
        }
        t.ie = t.ie & ~REACTIVE_CHECK | REACTIVE_DIRTY;
        insertIntoHeap(t, queueFor(t));
        schedule();
    }
}

export { READ_SLOW, clearSnapshots, computed, context, createEffectNode, currentOptimisticLane, effectStatusNotify, ext, isEqual, latestReadActive, markSnapshotScope, optimisticComputed, optimisticSignal, pendingCheckActive, prepareComputed, read, readNodeFast, recompute, refresh, releaseSnapshotScope, runWithOwner, setContextInternal, setEffectStatusNotify, setLatestReadActive, setMemo, setPendingCheckActive, setSignal, setSnapshotCapture, signal, snapshotCaptureActive, snapshotSources, stale, staleValues, statusNotifierOf, suppressComputedRecompute, tracking, untrack };