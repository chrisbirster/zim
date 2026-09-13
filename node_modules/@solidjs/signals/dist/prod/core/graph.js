import { CONFIG_AUTO_DISPOSE, STATUS_PENDING, REACTIVE_DISPOSED, REACTIVE_ZOMBIE, REACTIVE_RECOMPUTING_DEPS } from "./constants.js";

import { deleteFromHeap, queueFor } from "./heap.js";

import { disposeChildren } from "./owner.js";

import { bumpNotifyEpoch } from "./scheduler.js";

// https://github.com/stackblitz/alien-signals/blob/v2.0.3/src/system.ts#L100
function unlinkSubs(e) {
    const n = e.ut;
    const l = e.it;
    const o = e.ae;
    const u = e.en;
    if (o !== null) o.en = u; else n.rt = u;
    if (u !== null) u.ae = o; else {
        n.u = o;
        if (o === null) {
            n.o?.ft?.();
            // No more subscribers; only tear down if CONFIG_AUTO_DISPOSE is set.
            // A pending node is exempt: its in-flight async work (or the
            // transition holding it) is an observer — tearing down would orphan
            // the work and re-execute it on the next read. The settle path runs
            // this same last-one-out check when that observer releases (the
            // untracked-read dormancy sweep guards on pending identically).
                        const e = n;
            e.oe && e.T & CONFIG_AUTO_DISPOSE && !(e.ie & REACTIVE_ZOMBIE) && !(e.S & STATUS_PENDING) && unobserved(e);
        }
    }
    return l;
}

function trimStaleDeps(e) {
    const n = e.Ye;
    let l = n !== null ? n.it : e.nt;
    if (l !== null) {
        do {
            l = unlinkSubs(l);
        } while (l !== null);
        if (n !== null) n.it = null; else e.nt = null;
    }
}

// Shared by unobserved() and the disposeChildren child loop. The truthy guard
// (not `!== null`) matters: plain Owners in a child chain have no _deps field,
// and skipping early also avoids adding one (hidden-class churn) via the
// null-out below.
function clearDeps(e) {
    let n = e.nt;
    if (!n) return;
    do {
        n = unlinkSubs(n);
    } while (n !== null);
    e.nt = null;
    e.Ye = null;
}

function unobserved(e) {
    deleteFromHeap(e, queueFor(e));
    clearDeps(e);
    disposeChildren(e, true);
}

/**
 * Deferred dormancy for never-observed auto-dispose computeds (#3078).
 *
 * An untracked top-level read of a subscriber-less observation-lifecycle memo
 * used to call unobserved() inline at the end of read(). That kept the leak
 * closed (the compute links the memo into its deps' sub lists — without a
 * teardown point a never-observed memo is retained by its sources forever;
 * upstream alien-signals has exactly this retention), but it made reads
 * destructive: each read disposed the node, the next read revived it with a
 * full recompute in whatever ambient transition/lane context happened to be
 * current, so consecutive reads could return different answers with no write
 * in between.
 *
 * Instead, reads queue the node here and the scheduler sweeps at the top of
 * the next flush (before runHeap, so a same-tick dirtying is reclaimed
 * instead of recomputed). Reads become idempotent within a tick (the node
 * stays alive and serves its cache, uniform with observed memos) while
 * reclamation still happens within one microtask — the enqueue site arms
 * schedule(), so a flush is guaranteed even when no other work is queued.
 */ const dormantNodes = new Set;

function sweepDormant() {
    if (dormantNodes.size === 0) return;
    for (const e of dormantNodes) {
        // Re-validate at sweep time: the node may have gained a subscriber (its
        // lifecycle is the unlinkSubs cascade now), gone pending (in-flight async
        // is an observer; the settle path re-runs last-one-out), lost its
        // AUTO_DISPOSE bit (owner teardown strips it, #3024), or already been
        // torn down.
        if (!e.u && e.T & CONFIG_AUTO_DISPOSE && !(e.S & STATUS_PENDING) && !(e.ie & (REACTIVE_DISPOSED | REACTIVE_ZOMBIE))) {
            unobserved(e);
        }
    }
    dormantNodes.clear();
}

// https://github.com/stackblitz/alien-signals/blob/v2.0.3/src/system.ts#L52
function link(e, n, l = false) {
    // Repeat touches within one pass AND-combine `_pendingObserver`: a probe
    // read (`isPending(() => x())`) beside a value read of the same dep must
    // not relabel the value dependency as probe-only — the value read is what
    // real-error propagation and affects() coverage key off, regardless of
    // read order within the computation.
    const o = n.Ye;
    if (o !== null && o.ut === e) {
        o.me &&= l;
        return;
    }
    let u = null;
    const t = n.ie & REACTIVE_RECOMPUTING_DEPS;
    if (t) {
        u = o !== null ? o.it : n.nt;
        if (u !== null && u.ut === e) {
            u.nn = n.Ze;
            n.Ye = u;
            // First touch of this pass: the previous pass's label is stale.
                        u.me = l;
            return;
        }
    }
    // A link stamped with the current pass generation was created or reused
    // in-order during this recompute, i.e. it already sits in the validated
    // [deps.._depsTail] prefix — the O(1) equivalent of scanning the dep list
    // (the old alien-signals `isValidLink` walk, O(n²) when a computation
    // re-reads earlier deps non-consecutively, e.g. store leaf reads).
        const s = e.rt;
    if (s !== null && s.ce === n && (!t || s.nn === n.Ze)) {
        // Gen-matched during a recompute = repeat touch this pass (AND); outside
        // a recompute there is no pass boundary, so the latest read labels it.
        if (t) s.me &&= l; else s.me = l;
        return;
    }
    const r = n.Ye = e.rt = {
        ut: e,
        ce: n,
        it: u,
        en: s,
        ae: null,
        nn: n.Ze,
        me: l
    };
    if (o !== null) o.it = r; else n.nt = r;
    if (s !== null) s.ae = r; else e.u = r;
    // New subscriber edge: staged-rewrite skips (§12d) must not miss it.
        bumpNotifyEpoch();
}

export { clearDeps, dormantNodes, link, sweepDormant, trimStaleDeps, unlinkSubs, unobserved };