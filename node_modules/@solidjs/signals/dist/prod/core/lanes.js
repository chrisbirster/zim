import { NOT_PENDING, CONFIG_HAS_LANE } from "./constants.js";

import { ext } from "./core.js";

import { currentTransition, activeTransition } from "./scheduler.js";

// Map from optimistic signal to its lane (reused for multiple writes to same signal)
const signalLanes = new WeakMap;

// All active lanes (for cleanup on transition completion)
const activeLanes = new Set;

/**
 * Get an existing lane for a signal or create a new one.
 * Reuses lane for multiple writes to the same signal.
 */ function getOrCreateLane(n) {
    let e = signalLanes.get(n);
    if (e) {
        return findLane(e);
    }
    // Detect parent lane: _parentSource chains from pendingSignal → pendingValueComputed → original.
    // The child lane should not merge with the parent lane.
        const i = n.o?.Et;
    const t = i?.o?.Be;
    const r = t ? findLane(t) : null;
    e = {
        tn: n,
        Ae: new Set,
        rn: [ [], [] ],
        an: null,
        _e: activeTransition,
        sn: r
    };
    signalLanes.set(n, e);
    activeLanes.add(e);
    // A companion may have written before the owner's first optimistic write
    // (affects() as an action's first statement pokes the verdict companion of a
    // still lane-less node, #2887), leaving its lane parentless. Adopt it now:
    // parent-child is a property of the nodes, not of write order — otherwise
    // the owner's write merges the companion's subscribers into this lane and
    // their effects wait on its async instead of flushing immediately.
        adoptCompanionLane(n.o?.Ge, e);
    adoptCompanionLane(n.o?.ge, e);
    return e;
}

function adoptCompanionLane(n, e) {
    if (!n) return;
    const i = signalLanes.get(n);
    if (!i) return;
    const t = findLane(i);
    // Only the companion's own unmerged root is safely re-parentable: a root
    // that absorbed other lanes carries work that is not a child of this owner.
        if (t !== e && t.tn === n && !t.sn) t.sn = e;
}

/**
 * Union-find: find the root lane.
 */ function findLane(n) {
    while (n.an) n = n.an;
    return n;
}

/**
 * Merge two lanes when their dependency graphs overlap.
 */ function mergeLanes(n, e) {
    n = findLane(n);
    e = findLane(e);
    if (n === e) return n;
    e.an = n;
    // Move (not copy) the merged lane's work: after the merge all routing goes
    // through findLane() to the root, so anything left behind here is dead —
    // and anything *added* here later is a routing bug (INV-5).
        for (const i of e.Ae) n.Ae.add(i);
    e.Ae.clear();
    n.rn[0].push(...e.rn[0]);
    n.rn[1].push(...e.rn[1]);
    e.rn[0].length = 0;
    e.rn[1].length = 0;
    return n;
}

/**
 * Resolve a node's lane: follow union-find chain, verify active, clear if stale.
 */ function resolveLane(n) {
    const e = n.o?.Be;
    if (!e) return undefined;
    const i = findLane(e);
    if (activeLanes.has(i)) return i;
    if (n.o !== null) n.o.Be = undefined;
    return undefined;
}

function resolveTransition(n) {
    // An active override answers with its owner, not its lane: lanes are
    // scheduling affinity and a shared subscriber merges them across
    // transactions (#2912) — the merged root's _transition would hand this
    // node's override to whichever action wrote last through the shared
    // reader. Chase merge chains; a dead owner settled through another path.
    if (hasActiveOverride(n) && n.o?.Nt) {
        const e = ext(n).Nt = currentTransition(n.o?.Nt);
        if (e.fn !== true) return e;
        if (n.o !== null) n.o.Nt = null;
    }
    return resolveLane(n)?._e ?? n._e;
}

/**
 * Check if a node has an active optimistic override.
 */ function hasActiveOverride(n) {
    const e = n.o;
    return e !== null && e.De !== undefined && e.De !== NOT_PENDING;
}

/**
 * Assign or merge a lane onto a node. At convergence points (node already has
 * a different active lane), merge unless the node has an active override.
 */ function assignOrMergeLane(n, e) {
    const i = findLane(e);
    const t = n.o?.Be;
    if (t) {
        // If the subscriber's lane was merged into another lane, it's stale —
        // replace it with the new source lane instead of following the merge chain
        // (which would incorrectly merge the new lane into the old group)
        if (t.an) {
            ext(n).Be = e;
            n.T |= CONFIG_HAS_LANE;
            return;
        }
        const r = findLane(t);
        if (activeLanes.has(r)) {
            if (r !== i && !hasActiveOverride(n)) {
                // Parent-child lanes stay independent so isPending resolves without
                // waiting for the parent's async. The child keeps ownership.
                if (i.sn && findLane(i.sn) === r) {
                    ext(n).Be = e;
                    n.T |= CONFIG_HAS_LANE;
                } else if (r.sn && findLane(r.sn) === i) ; else mergeLanes(i, r);
            }
            return;
        }
    }
    ext(n).Be = e;
    n.T |= CONFIG_HAS_LANE;
}

export { activeLanes, assignOrMergeLane, findLane, getOrCreateLane, hasActiveOverride, mergeLanes, resolveLane, resolveTransition, signalLanes };