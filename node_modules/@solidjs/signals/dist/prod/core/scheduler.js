import { EFFECT_RENDER, EFFECT_USER, STATUS_PENDING, REACTIVE_IN_HEAP_HEIGHT, REACTIVE_DISPOSED, REACTIVE_ZOMBIE, NOT_PENDING, CONFIG_HAS_COMPANIONS, EFFECT_TRACKED, CONFIG_HAS_LANE, CONFIG_HAS_SNAPSHOT, REACTIVE_RECOMPUTING_DEPS, REACTIVE_MISSED_WAKE, CONFIG_IN_SNAPSHOT_SCOPE, REACTIVE_SNAPSHOT_STALE, REACTIVE_OPTIMISTIC_DIRTY, REACTIVE_REASK, REACTIVE_MANUAL_WRITE, STATUS_UNINITIALIZED } from "./constants.js";

import { currentOptimisticLane } from "./core.js";

import { DEV } from "./dev.js";

import { NotReadyError } from "./error.js";

import { sweepDormant } from "./graph.js";

import { runHeap, deleteFromHeap, enqueueSub } from "./heap.js";

import { activeLanes, assignOrMergeLane, findLane } from "./lanes.js";

export { getOrCreateLane, hasActiveOverride, mergeLanes, resolveLane } from "./lanes.js";

import { devCheckFlushStart, devCheckActiveOverrides, devCensusCompanions, devCheckQuiescent } from "./invariants.js";

const transitions = new Set;

const dirtyQueue = {
    eE: new Array(2e3).fill(undefined),
    tE: false,
    xe: 0,
    EE: 0
};

const zombieQueue = {
    eE: new Array(2e3).fill(undefined),
    tE: false,
    xe: 0,
    EE: 0
};

/** runHeap callback that discards a queued zombie recompute instead of running
 * it: unlink pure recompute entries; strip just the recompute bit from dirtied
 * height-adjust entries so their height work still happens. */ function cancelZombieRecompute(e) {
    if (e.ie & REACTIVE_IN_HEAP_HEIGHT) e.ie &= -12; else {
        deleteFromHeap(e, zombieQueue);
        e.ie &= -4;
    }
}

let clock = 0;

let activeTransition = null;

let scheduled = false;

let halted = false;

let haltNotified = false;

let syncDepth = 0;

let projectionWriteActive = false;

// Store property nodes that were created solely to carry a pending write (no
// subscribers at write time). Swept after each flush that commits pending
// values — any still without subs get disposed via their `_unobserved` hook,
// releasing the slot in the parent store's node map.
const transientStoreNodes = new Set;

function canUseSimpleSyncFlush(e) {
    const t = e.m;
    return transitions.size === 0 && activeLanes.size === 0 && e.Qt.length === 0 && t.Ke.length === 0 && t.A.length === 0 && t.Tn.size === 0 && transientStoreNodes.size === 0;
}

function sweepTransientStoreNodes() {
    if (transientStoreNodes.size === 0) return;
    for (const e of transientStoreNodes) {
        if (e.u !== null) {
            transientStoreNodes.delete(e);
            continue;
        }
        if (e.Pe !== NOT_PENDING) continue;
        if (e.o?.De !== undefined && e.o?.De !== NOT_PENDING) continue;
        // A live affects() mark keeps the node addressable: sweeping it would
        // detach the refcount from the slot (a fresh probe would upsert a new,
        // unmarked node for the same property).
                if (e.o?.t) continue;
        transientStoreNodes.delete(e);
        e.o?.ft?.();
    }
}

/**
 * Toggles the dev-mode "must be inside a `<Loading>` boundary" enforcement
 * window. Only `render()` calls this — wrapping the initial mount so that a
 * top-level uncaught async read surfaces the diagnostic. Not part of the
 * user-facing API.
 *
 * @internal
 */ function enforceLoadingBoundary(e) {}

function setProjectionWriteActive(e) {
    projectionWriteActive = e;
}

/**
 * Ambient work IS a transaction: the global queue always carries one
 * current-transaction-shaped batch (`globalQueue._batch`). With no transition
 * active, registrations (pending commits, optimistic nodes, affects marks,
 * optimistic stores) land in a plain ambient batch that the plain flush
 * finalizes; when a transition initializes it adopts the ambient batch's
 * contents and `_batch` becomes the transition itself, so later registrations
 * land there directly — no per-field aliasing.
 */ function createBatch() {
    return {
        Te: clock,
        yt: [],
        Ne: new Map,
        Ke: [],
        A: [],
        Tn: new Set,
        ue: [],
        bt: {
            Lt: [ [], [] ],
            Qt: []
        },
        fn: false,
        cn: new Set
    };
}

function mergeTransitionState(e, t) {
    t.fn = e;
    e.ue.push(...t.ue);
    for (const i of activeLanes) if (i._e === t) i._e = e;
    if (t.Ke.length) {
        // Move (don't copy): the global queue's batch may still be the outgoing
        // transition, and the adoption pass in initTransition would re-push its
        // contents into the target — duplicating every entry.
        e.Ke.push(...t.Ke);
        t.Ke.length = 0;
    }
    if (t.A.length) {
        // Move (don't copy): the global queue's batch may still be the outgoing
        // transition, and the adoption pass in initTransition would re-push its
        // contents into the target — double-releasing every mark.
        e.A.push(...t.A);
        t.A.length = 0;
    }
    for (const i of t.Tn) e.Tn.add(i);
    // Patch-channel stash (store/next/patch.ts): entries held for the outgoing
    // transition must ride the merge like every other per-transition
    // collection — releaseBatch only reads the COMMITTING transition's stash,
    // so a stranded sidecar would silently drop its patches. Move (don't
    // copy), same aliasing rule as the collections above. The field is an
    // expando so this module stays free of patch imports (pay-for-use).
        const i = t.Mt;
    if (i !== undefined) {
        t.Mt = undefined;
        let n = e.Mt;
        if (n !== undefined) n.push(...i); else n = e.Mt = i;
        // Retarget the entries' coalescing stamps to the surviving stash
        // (opaque backref contract with store/next/patch.ts): without this a
        // post-merge emission misses the stamp and pushes a SECOND entry —
        // the record's patch applies twice at commit (re-audit 5, P1-2).
                for (let e = 0; e < i.length; e++) {
            const t = i[e].pc;
            if (t !== undefined && t.qe === i[e]) t.qa = n;
        }
    }
    for (const [i, n] of t.Ne) {
        let t = e.Ne.get(i);
        if (!t) e.Ne.set(i, t = new Set);
        for (const e of n) t.add(e);
    }
    for (const i of t.cn) e.cn.add(i);
}

function schedule() {
    if (halted) {
        notifyHalted();
        return;
    }
    if (scheduled) return;
    scheduled = true;
    if (!syncDepth && !globalQueue.En && !projectionWriteActive) queueMicrotask(flush);
}

/**
 * Permanently halts the reactive system. Called when a user error escapes
 * every boundary — app state is undefined at that point, so scheduling stops
 * entirely rather than limping along with a half-applied update.
 */ function haltReactivity(e) {
    if (halted) return;
    halted = true;
    let t = "[REACTIVITY_HALTED]";
    // Log the cause here too: callers rethrow it, but a creation-time throw
    // unwinds through ancestor recomputes that convert it to status instead of
    // surfacing it (#2884), so the rethrow alone cannot guarantee visibility.
        e === undefined ? console.error(t) : console.error(t, e);
}

// Logs on the first write after a halt so a frozen interaction is traceable.
function notifyHalted() {
    if (haltNotified) return;
    haltNotified = true;
    console.error("[REACTIVITY_HALTED]");
}

/** @internal Test/dev-reload hook. Revives scheduling after a halt. */ function resetErrorHalt() {
    halted = false;
    haltNotified = false;
}

// Identifies one child-traversal pass in `Queue.run` so a rescan after the
// child list shifts can tell "already run this pass" from "still pending".
let queueRunToken = 0;

class Queue {
    ke=null;
    Lt=[ [], [] ];
    Qt=[];
    Vt=0;
    created=clock;
    addChild(e) {
        this.Qt.push(e);
        e.ke = this;
    }
    removeChild(e) {
        const t = this.Qt.indexOf(e);
        if (t >= 0) {
            this.Qt.splice(t, 1);
            e.ke = null;
        }
    }
    notify(e, t, i, n) {
        if (this.ke) return this.ke.notify(e, t, i, n);
        return false;
    }
    run(e) {
        if (this.Lt[e - 1].length) {
            const t = this.Lt[e - 1];
            this.Lt[e - 1] = [];
            runQueue(t, e);
        }
        // Effects run here can dispose owners, and disposal removes queues from
        // this list — the running child itself, an earlier sibling, or several at
        // once. A plain index walk then skips whatever shifted into the cursor.
        // Stamping each child before it runs makes the pass idempotent, so a shift
        // can be recovered by rescanning from the front and every child still runs
        // exactly once. Children appended mid-pass carry a stale stamp and run,
        // matching the previous live-array behaviour.
                const t = this.Qt;
        const i = ++queueRunToken;
        for (let n = 0; n < t.length; ) {
            const s = t[n];
            if (s.Vt !== i) {
                s.Vt = i;
                s.run?.(e);
                if (t[n] !== s) {
                    n = 0;
                    continue;
                }
            }
            n++;
        }
    }
    enqueue(e, t) {
        if (e) {
            // Route to lane's effect queue if we're in an optimistic recomputation
            if (currentOptimisticLane) {
                const i = findLane(currentOptimisticLane);
                i.rn[e - 1].push(t);
            } else {
                this.Lt[e - 1].push(t);
            }
        }
        schedule();
    }
    stashQueues(e) {
        e.Lt[0].push(...this.Lt[0]);
        e.Lt[1].push(...this.Lt[1]);
        this.Lt = [ [], [] ];
        for (let t = 0; t < this.Qt.length; t++) {
            let i = this.Qt[t];
            let n = e.Qt[t];
            if (!n) {
                n = {
                    Lt: [ [], [] ],
                    Qt: []
                };
                e.Qt[t] = n;
            }
            i.stashQueues(n);
        }
    }
    restoreQueues(e) {
        this.Lt[0].push(...e.Lt[0]);
        this.Lt[1].push(...e.Lt[1]);
        for (let t = 0; t < e.Qt.length; t++) {
            const i = e.Qt[t];
            let n = this.Qt[t];
            if (n) n.restoreQueues(i);
        }
    }
}

class GlobalQueue extends Queue {
    En=false;
    // The current transaction-shaped batch: a plain ambient batch while no
    // transition is active, the active transition itself after initTransition.
    m=createBatch();
    static Ce;
    static Fe;
    static tt;
    static Bt=null;
    // Store-side hook: drops a keyless affects() mark's identity scope when the
    // carrier node's last registration releases (wired by store.ts, mirroring
    // _clearOptimisticStore).
    static p=null;
    // affects()-side hooks (wired by affects.ts, mirroring _update): the mark
    // engine — count/register/release — lives with the feature. Every call site
    // is gated by state only that module creates, so `!` invocations are safe
    // once the gate holds.
    static G=null;
    static M=null;
    static N=null;
    // External-source bridge (wired by enableExternalSource(); null while no
    // config is active — including after _resetExternalSourceConfig()).
    static Rt=null;
    static Gt=null;
    // Verdict-layer hooks (wired by verdict.ts when isPending()/latest() are
    // imported; null in apps that never use them). Call sites either guard for
    // null or sit behind state only the verdict layer can create (`!` is safe
    // there: `_pendingSignal`/`_latestValueComputed` are only ever assigned by
    // verdict.ts, and `pendingCheckActive`/`latestReadActive` only flip inside
    // isPending()/latest()).
    static Oe=null;
    static de=null;
    static ye=null;
    static un=null;
    static Pt=null;
    static Dt=null;
    static Ht=null;
    static Je=null;
    static k=null;
    static wt=null;
    // Re-asks probes whose verdict was provisionally suppressed by a fresh read
    // of a held value, once the transaction gains an async blocker (#3028).
    static jt=null;
    // Optimistic-engine hooks (wired by core/optimistic.ts via
    // installOptimisticEngine(), called from verdict.ts / createOptimistic /
    // createOptimisticStore — every module that can create optimistic state).
    // Call sites are gated by state only the engine can create: an
    // `_overrideValue` slot, a lane in `activeLanes`, an `_optimisticNodes`
    // entry, or a non-null `currentOptimisticLane`, so `!` invocations are safe
    // once the gate holds.
    static kt=null;
    static dn=null;
    static In=null;
    static Nn=null;
    static _n=null;
    /** Patch-channel optimistic drain (next/patch.ts): optimistic emissions
     * apply at lane-effect timing — visible in flight, unlike the regular
     * effect queues an action stashes. Injected; null when unused. */
    static ln=null;
    static Ft=null;
    static ht=null;
    static gt=null;
    static je=null;
    static $e=null;
    static ze=null;
    static An=null;
    flush() {
        if (this.En) return;
        // Fast drain: nothing in flight but plain pending commits — no dirty
        // computeds, no queued effects, no child queues, no transitions/lanes/
        // optimistic state. Commit and go; anything a commit hook schedules
        // (companion snaps, store folds notifying subs) re-arms `scheduled`
        // below and the outer drain loop takes the full spine next round.
                if (activeTransition === null && dirtyQueue.EE < dirtyQueue.xe && this.Lt[0].length === 0 && this.Lt[1].length === 0 && this.Qt.length === 0 && canUseSimpleSyncFlush(this)) {
            this.En = true;
            try {
                // Sweep first: unobserved() pulls swept nodes out of the dirty heap,
                // so a dormant memo dirtied in the same tick is reclaimed instead of
                // recomputed (matching the old inline dispose-on-read counts).
                sweepDormant();
                commitPendingNodes();
            } finally {
                this.En = false;
            }
            clock++;
            scheduled = dirtyQueue.EE >= dirtyQueue.xe || this.Lt[0].length !== 0 || this.Lt[1].length !== 0 || this.m.yt.length !== 0;
            return;
        }
        this.En = true;
        try {
            if (false) ;
            // Before runHeap for the same reason as the fast drain above; late
            // subscribers (an effect reading a swept memo this flush) revive it,
            // which is the pay-for-use contract.
                        sweepDormant();
            runHeap(dirtyQueue, GlobalQueue.Ce);
            if (activeTransition) {
                const e = transitionComplete(activeTransition);
                if (!e) {
                    const e = activeTransition;
                    // When the parking batch IS the transition, all of its writes commit
                    // only with it — every zombie recompute they queued would run against
                    // a world the zombie never displays (zombies render mainline until
                    // commit), so cancel them instead of running them. Only an ambient
                    // batch's mainline writes (the #2916 shape below) legitimately reach
                    // zombies here. Height-adjust entries still process normally: a
                    // dirtied one keeps its height flag and falls through to runHeap's
                    // adjustHeight path on the next pass of the bucket.
                                        runHeap(zombieQueue, this.m === e ? cancelZombieRecompute : GlobalQueue.Ce);
                    // Detach: the stashed transition keeps its batch; ambient work that
                    // follows lands in a fresh one. If the batch is already a separate
                    // ambient one — action done() restored activeTransition without
                    // adopting the batch, and an ordinary write landed there before
                    // the scheduled flush (#2916) — keep it: replacing it would strand
                    // its queued pending nodes with held _pendingValues forever.
                                        if (this.m === e) currentBatch = this.m = createBatch();
                    // Run lane effects immediately (before stashing) - lanes with no pending async
                                        if (activeLanes.size) {
                        GlobalQueue._n(EFFECT_RENDER);
                        GlobalQueue._n(EFFECT_USER);
                    }
                    this.stashQueues(e.bt);
                    clock++;
                    // A kept ambient batch may hold pending nodes (#2916): stay
                    // scheduled so the outer drain loop commits them via the plain
                    // flush path instead of leaving them until the next natural flush.
                                        scheduled = dirtyQueue.EE >= dirtyQueue.xe || this.m.yt.length > 0;
                    reassignPendingTransition(e.yt);
                    activeTransition = null;
                    finalizePureQueue(null, true);
                    return;
                }
                const t = activeTransition;
                const i = this.m;
                i !== t && i.yt.push(...t.yt);
                this.restoreQueues(t.bt);
                transitions.delete(t);
                activeTransition = null;
                reassignPendingTransition(i.yt);
                finalizePureQueue(t);
                if (i === t) {
                    // Drop the dead Transition wrapper but keep its (drained) containers
                    // as the ambient batch — late registrations during finalization live
                    // there and must survive to the next flush.
                    const e = createBatch();
                    e.yt = i.yt;
                    e.Ke = i.Ke;
                    e.A = i.A;
                    e.Tn = i.Tn;
                    currentBatch = this.m = e;
                }
            } else {
                if (canUseSimpleSyncFlush(this)) {
                    commitPendingNodes();
                    if (dirtyQueue.EE >= dirtyQueue.xe) {
                        runHeap(dirtyQueue, GlobalQueue.Ce);
                        commitPendingNodes();
                    }
                } else {
                    if (transitions.size) runHeap(zombieQueue, GlobalQueue.Ce);
                    finalizePureQueue();
                }
            }
            clock++;
            // Check if finalization added items to the heap (from optimistic reversion)
                        scheduled = dirtyQueue.EE >= dirtyQueue.xe;
            // Run lane effects first (for ready lanes), then regular effects
                        activeLanes.size && GlobalQueue._n(EFFECT_RENDER);
            this.run(EFFECT_RENDER);
            activeLanes.size && GlobalQueue._n(EFFECT_USER);
            this.run(EFFECT_USER);
            if (false) ;
            if (false && !scheduled && !activeTransition && transitions.size === 0 && activeLanes.size === 0) ;
            if (false) ;
        } finally {
            this.En = false;
        }
    }
    notify(e, t, i, n) {
        // Only track async if the boundary is propagating STATUS_PENDING (not caught by boundary)
        if (t & STATUS_PENDING) {
            if (i & STATUS_PENDING) {
                const t = n !== undefined ? n : e.o?._;
                // A visibility-only mark notification (the affects() boundary
                // channel) updates display state on its way up but must be invisible
                // to completion accounting BY CONSTRUCTION: it never registers a
                // reporter and never counts toward the loading-boundary diagnostic.
                                if (t?.l) return true;
                if (activeTransition && t) {
                    const i = t.source;
                    let n = activeTransition.Ne.get(i);
                    if (!n) activeTransition.Ne.set(i, n = new Set);
                    const s = n.size;
                    n.add(e);
                    if (n.size !== s) {
                        schedule();
                        GlobalQueue.jt?.(activeTransition);
                    }
                }
            }
            return true;
        }
        return false;
    }
    initTransition(e) {
        if (e) e = currentTransition(e);
        if (e && e === activeTransition) return;
        if (!e && activeTransition && activeTransition.Te === clock) return;
        if (!activeTransition) {
            activeTransition = e ?? createBatch();
        } else if (e) {
            const t = activeTransition;
            mergeTransitionState(e, t);
            transitions.delete(t);
            activeTransition = e;
        }
        transitions.add(activeTransition);
        activeTransition.Te = clock;
        const t = this.m;
        if (t !== activeTransition) {
            // Adopt the ambient batch into the transaction, then make the
            // transaction the batch so later registrations land there directly.
            // Pending and optimistic nodes are re-stamped as the transaction's;
            // marks don't hijack the node's _transition — a mark on a plain signal
            // must not entangle unrelated writes to it; the same rule holds one hop
            // downstream: propagation never queues pended subscribers as pending
            // nodes, see propagateAffectsMark, #2893.
            for (let e = 0; e < t.yt.length; e++) {
                const i = t.yt[e];
                i._e = activeTransition;
                activeTransition.yt.push(i);
            }
            for (let e = 0; e < t.Ke.length; e++) {
                const i = t.Ke[e];
                i._e = activeTransition;
                activeTransition.Ke.push(i);
            }
            if (t.A.length) activeTransition.A.push(...t.A);
            for (const e of t.Tn) activeTransition.Tn.add(e);
            // Gated readers recorded against the ambient batch move with it: their
            // replay-at-commit now happens at the transaction's completion.
                        if (t.cn.size) {
                for (const e of t.cn) activeTransition.cn.add(e);
                t.cn.clear();
            }
            currentBatch = this.m = activeTransition;
        }
        for (const e of activeLanes) {
            if (!e._e) e._e = activeTransition;
        }
    }
}

function queuePendingNode(e) {
    currentBatch.yt.push(e);
}

// Sticky: flips true on the first refresh() ever (the only setter of
// REACTIVE_REASK) so the hot notification loop skips the per-subscriber flag
// clear entirely in apps that never refresh.
let reaskArmed = false;

/** §12d: bumped by every recompute and every new subscriber edge. A node's
 * staged-rewrite skip is sound only while NOTHING recomputed or linked since
 * its last notify — a mid-batch pull can clean a marked subscriber, and a
 * skipped re-write would leave it stale. */ let notifyEpoch = 0;

function bumpNotifyEpoch() {
    notifyEpoch++;
}

function armReaskClear() {
    reaskArmed = true;
}

function insertSubs(e, t = false) {
    // §12d: stamp before walking — setSignal's staged-rewrite fast path skips
    // the next walk for this node while the epoch holds (marking is idempotent).
    e._t = notifyEpoch;
    // Get source lane: prefer node's own lane over current context
    // This is important for isPending signals which need their own lane to flush immediately
    // Presence bits gate the optional-slot probes (see constants.ts): one
    // masked read of the always-present _config instead of missing-property
    // lookups in the hottest notify loop. Bits are sticky — the field read
    // stays authoritative when a bit is set.
        const i = e.T;
    const n = (i & CONFIG_HAS_LANE ? e.o?.Be : undefined) || currentOptimisticLane;
    const s = (i & CONFIG_HAS_SNAPSHOT) !== 0 && e.o?.Qe !== undefined;
    const o = reaskArmed;
    for (let i = e.u; i !== null; i = i.ae) {
        const e = i.ce;
        // A value-change notification is a new question for the subscriber: any
        // pending re-ask mark (refresh) it carried is superseded.
                if (o) e.ie &= ~REACTIVE_REASK;
        // Missed-wake latch (#3037): this write is landing while the subscriber
        // is mid-recompute (a nested pull committing beneath its reads), and the
        // heap refuses RECOMPUTING nodes. A gen-current link means the pass
        // already validated this dep — the value it read is now stale — so latch
        // for recompute's tail to reschedule. Untouched links need no latch (the
        // pass either re-reads them fresh or trims them), and neither does the
        // tail link: it is the read IN FLIGHT — read() links before it pulls, so
        // this very commit is what that read returns.
                if (e.ie & REACTIVE_RECOMPUTING_DEPS && i.nn === e.Ze && i !== e.Ye) e.ie |= REACTIVE_MISSED_WAKE;
        if (s && e.T & CONFIG_IN_SNAPSHOT_SCOPE) {
            e.ie |= REACTIVE_SNAPSHOT_STALE;
            continue;
        }
        if (t && n) {
            e.ie |= REACTIVE_OPTIMISTIC_DIRTY;
            assignOrMergeLane(e, n);
        } else if (t) {
            e.ie |= REACTIVE_OPTIMISTIC_DIRTY;
            // No source lane means reversion - clear subscriber's lane so effects go to regular queue
                        if (e.o) e.o.Be = undefined;
        }
        enqueueSub(e);
    }
}

function commitPendingNode(e) {
    const t = e;
    if (!t.oe) {
        if (e.Pe !== NOT_PENDING) {
            e.be = e.Pe;
            e.Pe = NOT_PENDING;
        }
        if (e.T & CONFIG_HAS_COMPANIONS) GlobalQueue.un(e);
        return;
    }
    if (e.Pe !== NOT_PENDING) {
        e.be = e.Pe;
        e.Pe = NOT_PENDING;
        // Set _modified for effects, but not for tracked effects (they handle their own scheduling)
                if (e.Re && e.Re !== EFFECT_TRACKED) e.Xe = true;
    }
    // The committed hold is the first observable answer for a loading-window
    // node — the window closes here, not at compute time (#2990). Unconditional
    // store to an always-present computed slot.
        t.Ie = false;
    t.ie &= ~REACTIVE_MANUAL_WRITE;
    if (!(t.S & STATUS_PENDING)) t.S &= ~STATUS_UNINITIALIZED;
    if (t.o != null && (t.o.qe !== null || t.o.We !== null)) GlobalQueue.Fe(t, false, true);
    if (e.T & CONFIG_HAS_COMPANIONS) GlobalQueue.un(e);
}

// Store commit hook (INTERNALS-STORE-STATE.md §3): installed by the store
// module at init (same treeshakeable pattern as _resolveOptimistic /
// _clearOptimisticStores). Folds committed store-node values into their
// backing objects at the same moment pending values commit — the single
// mutation point of the owned-raw model.
let storeCommitHook = null;

function setStoreCommitHook(e) {
    storeCommitHook = e;
}

/** Patch-channel release hook (next/patch.ts): transition-stamped patch
 * emissions are released when THEIR batch commits. Transitions never
 * abort: failed actions still commit (only optimistic overrides revert),
 * and merged-away transitions hand their stash to the survivor
 * (mergeTransitionState) — every stash drains exactly once. Injected like
 * storeCommitHook to stay tree-shakeable. */ let patchCommitHook = null;

function setPatchCommitHook(e) {
    patchCommitHook = e;
}

function commitPendingNodes() {
    const e = currentBatch.yt;
    for (let t = 0; t < e.length; t++) {
        commitPendingNode(e[t]);
    }
    e.length = 0;
    storeCommitHook?.();
    patchCommitHook?.(currentBatch);
}

function finalizePureQueue(e = null, t = false) {
    // For incomplete transitions, skip pending resolution and optimistic reversion
    // For completing transitions or no-transition, resolve pending and revert optimistic
    const i = !t;
    if (i) commitPendingNodes();
    if (!t && globalQueue.Qt.length) checkBoundaryChildren(globalQueue);
    const n = dirtyQueue.EE >= dirtyQueue.xe;
    if (n) runHeap(dirtyQueue, GlobalQueue.Ce);
    if (i) {
        if (n) commitPendingNodes();
        // The settling batch: the completing transaction's, or the ambient one.
                const t = e ?? globalQueue.m;
        // Optimistic reversion: a non-empty batch means _optimisticWrite ran,
        // which installed the engine's hooks.
                if (t.Ke.length) GlobalQueue.dn(t.Ke);
        // Replay entanglement: subs recorded by the read-time gate get rescheduled
        // so they re-run with the now-committed values visible. The ambient batch
        // replays too — laneReadsCommitted records readers whose committed-view
        // read hid a same-tick plain write that just committed above (#2963).
                if (t.cn.size) {
            for (const e of t.cn) {
                if (e.ie & REACTIVE_DISPOSED) continue;
                enqueueSub(e);
            }
            t.cn.clear();
            // A completing transition keeps the outer flush loop alive by itself;
            // the ambient batch needs the re-arm or the replay sits in the heap
            // until the next unrelated write.
                        schedule();
        }
        // Declared motion ends with the transaction: settle (or plain flush end
        // for ambient marks) releases each registration's refcount. A non-empty
        // batch means registerAffectsMark ran, which installed the hook. Marks
        // held boundary display state through the visual channel, and their
        // release is the display-state update point — re-run the boundary sweep
        // (the earlier sweep above ran while the marks were still live).
                if (t.A.length) {
            GlobalQueue.G(t.A);
            if (globalQueue.Qt.length) checkBoundaryChildren(globalQueue);
        }
        // A non-empty set means trackOptimisticStore ran, which installed the
        // hook; the hook iterates, clears, and schedules (keeping the loop out of
        // core lets esbuild shake it — rollup already folds the null guard). The
        // completing transition scopes the clear to its own layer keys (#2899).
                if (t.Tn.size) GlobalQueue.Bt(t.Tn, e);
        sweepTransientStoreNodes();
        // Lanes only enter activeLanes through the engine's getOrCreateLane.
                if (activeLanes.size) GlobalQueue.Nn(e);
    }
}

function checkBoundaryChildren(e) {
    for (const t of e.Qt) {
        t.se?.();
        checkBoundaryChildren(t);
    }
}

/**
 * Count of live `affects()` registrations across the system (including
 * store-scope inherited marks). Gates the read-path mark check in `read()` so
 * graphs that never use the feature pay one integer compare.
 */ let activeAffectsMarks = 0;

/**
 * Counter mutation seam for the mark engine in affects.ts: an imported `let`
 * binding is read-only, and the read-path gate above must stay a plain module
 * variable so `read()` pays one integer compare, not a function call.
 *
 * @internal
 */ function shiftAffectsMarks(e) {
    activeAffectsMarks += e;
}

function reassignPendingTransition(e) {
    for (let t = 0; t < e.length; t++) {
        e[t]._e = activeTransition;
    }
}

const globalQueue = new GlobalQueue;

// Hot-path mirror of `globalQueue._batch`: `queuePendingNode` runs once per
// staged write and `commitPendingNodes` once per flush, and the extra
// property hop through `_batch` was a measured instruction-count regression
// (CodSpeed update1to1, PR #2905). The field stays authoritative for
// cross-module readers; every `_batch` assignment updates both.
let currentBatch = globalQueue.m;

function flush(e) {
    if (e) {
        syncDepth++;
        try {
            return e();
        } finally {
            // Decrement even if the drain throws (a throwing effect): a leaked
            // syncDepth would stop `schedule()` from ever queuing a microtask again.
            try {
                flush();
            } finally {
                syncDepth--;
            }
        }
    }
    if (globalQueue.En) {
        return;
    }
    if (halted) return;
    // `flush()` is an explicit drain point, so it must also process an active
    // transition even if no microtask was scheduled for it yet.
        while (scheduled || activeTransition) {
        globalQueue.flush();
    }
}

function runQueue(e, t) {
    for (let i = 0; i < e.length; i++) e[i](t);
}

function reporterBlocksSource(e, t) {
    if (e.ie & (REACTIVE_ZOMBIE | REACTIVE_DISPOSED)) return false;
    if (e.o?.le?.has(t)) return true;
    for (let i = e.nt; i; i = i.it) {
        let e = i.ut;
        while (e) {
            if (e === t || e.lt === t) return true;
            e = e.o?.Et;
        }
    }
    return !!(e.S & STATUS_PENDING && e.o?._ instanceof NotReadyError && e.o?._.source === t);
}

function transitionComplete(e) {
    if (e.fn) return true;
    if (e.ue.length) return false;
    let t = true;
    for (const [i, n] of e.Ne) {
        let s = false;
        for (const e of n) {
            if (reporterBlocksSource(e, i)) {
                s = true;
                break;
            }
            n.delete(e);
        }
        if (!s) e.Ne.delete(i); else if (i.S & STATUS_PENDING && i.o?._?.source === i) {
            t = false;
            break;
        }
    }
    // Override blockage lives with the engine (absent hook = "no optimistic
    // blockage"); the hook's loops over _optimisticNodes/_optimisticStores are
    // no-ops when the transition holds neither, so no pre-check is needed.
        if (t && GlobalQueue.In?.(e)) t = false;
    t && (e.fn = true);
    return t;
}

function currentTransition(e) {
    while (e.fn && typeof e.fn === "object") e = e.fn;
    return e;
}

function runInTransition(e, t) {
    const i = activeTransition;
    try {
        activeTransition = currentTransition(e);
        return t();
    } finally {
        activeTransition = i;
    }
}

export { GlobalQueue, Queue, activeAffectsMarks, activeLanes, activeTransition, armReaskClear, assignOrMergeLane, bumpNotifyEpoch, clock, currentTransition, dirtyQueue, enforceLoadingBoundary, finalizePureQueue, findLane, flush, globalQueue, haltReactivity, insertSubs, notifyEpoch, patchCommitHook, projectionWriteActive, queuePendingNode, reaskArmed, resetErrorHalt, runInTransition, schedule, setPatchCommitHook, setProjectionWriteActive, setStoreCommitHook, shiftAffectsMarks, storeCommitHook, zombieQueue };