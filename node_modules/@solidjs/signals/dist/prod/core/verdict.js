import { NOT_PENDING, REACTIVE_DISPOSED, REACTIVE_DIRTY, REACTIVE_CHECK, unwrapOverride, REACTIVE_ZOMBIE, STATUS_UNINITIALIZED, STATUS_PENDING, REACTIVE_OPTIMISTIC_DIRTY, REACTIVE_MANUAL_WRITE, CONFIG_HAS_COMPANIONS, CONFIG_CHILD_COMPANIONS, STATUS_ERROR, REACTIVE_RECOMPUTING_DEPS } from "./constants.js";

import { setSignal, prepareComputed, read, context, stale, currentOptimisticLane, tracking, ext, setLatestReadActive, setContextInternal, optimisticComputed, setPendingCheckActive, latestReadActive, optimisticSignal, pendingCheckActive } from "./core.js";

import { NotReadyError } from "./error.js";

import { link } from "./graph.js";

import { insertIntoHeap, queueFor, markHeap, enqueueSub } from "./heap.js";

import "./invariants.js";

import { findLane, hasActiveOverride, assignOrMergeLane } from "./lanes.js";

import { installOptimisticEngine } from "./optimistic.js";

import { GlobalQueue, insertSubs, schedule, activeTransition, currentTransition, activeAffectsMarks } from "./scheduler.js";

/**
 * The isPending()/latest() verdict layer, moved out of core.ts. Importing this
 * module installs the companion-maintenance hooks on GlobalQueue; apps that
 * never import isPending/latest never pay for any of it.
 */
// Companions (pending signals / latest shadows) are optimistic nodes: their
// writes go through the optimistic write path and their reversion rides the
// same lanes, so the verdict layer brings the engine with it.
installOptimisticEngine();

let pendingProbe = null;

/**
 * Probes whose verdict was suppressed by the fresh-read pairing rule while
 * the held write's fate was still undecided (see recordFreshRead /
 * wakeSuppressedProbes): held node → the wrapper computeds that probed it.
 * Entries die with the hold — the commit/revert snap clears them.
 */ const suppressedProbes = new Map;

/**
 * Get or create the pending signal for a node (lazy).
 * Used by isPending() to track pending state reactively.
 */
/** #3038: register a companion-carrying firewall child on its firewall's
 * companion set and arm the post-recompute snap (CONFIG_CHILD_COMPANIONS is
 * the one-load gate at the call sites). The snap then iterates exactly the
 * children someone asked verdicts of — O(companions) — never the full
 * `_child` chain, which carries one node per materialized leaf (the
 * O(all-leaves-ever-read)-per-update pathology). Entries are permanent like
 * the companions themselves; a store with no leaf-level isPending()/latest()
 * reads never allocates the set or pays the walk. */ function markFirewallChildCompanions(e) {
    const t = e.lt;
    if (!t) return;
    t.T |= CONFIG_CHILD_COMPANIONS;
    (ext(t).It ??= new Set).add(e);
}

function getPendingSignal(e) {
    let t = e.o?.Ge;
    if (!t) {
        // Start false, write true if pending - ensures reversion returns to false
        t = optimisticSignal(false, {
            ownedWrite: true
        });
        ext(e).Ge = t;
        e.T |= CONFIG_HAS_COMPANIONS;
        markFirewallChildCompanions(e);
        ext(t).Et = e;
        if (computePendingState(e)) setSignal(t, true);
    }
    return t;
}

function collectPendingSources(e) {
    if (!pendingProbe) return;
    pendingProbe.sources.add(e);
    const t = e.lt || e;
    if (t !== e) pendingProbe.sources.add(t);
}

/**
 * Adds a node to the active isPending() probe without reading it. The store's
 * untracked-probe fallback (`witnessAffectsMark`) reaches this through
 * `GlobalQueue._witnessAffects` — its callers guard on `pendingCheckActive`,
 * which only flips inside `isPending()`, so the hook is always installed by
 * the time it can fire.
 */ function witnessAffects(e) {
    pendingProbe?.sources.add(e);
}

/**
 * The affects() coverage walk — the read half of the dedicated mark channel.
 * A node is covered by a live mark iff it carries one (`_affectsCount`) or
 * derives, through its CURRENT deps (hopping store firewalls), from a node
 * that does. Pull-based coverage means graph rewires, mid-window recomputes,
 * and probe-triggered recomputes can never strand or strip a mark — there is
 * nothing stored downstream to corrupt. Probe-created links
 * (`_pendingObserver`) are skipped so an `isPending` wrapper memo never
 * inherits the coverage it reports on.
 */ function markWalk(e, t) {
    if (e.o?.t) return true;
    // A real error outranks an inherited mark (A16/A24c): an errored node
    // answers probes with its error, not a coverage verdict, and coverage does
    // not flow through it — matching the rails' behavior, where propagation
    // stopped at errored nodes. A DIRECT mark on an errored node still reads
    // pending (the count check above), also matching.
        if (e.S & STATUS_ERROR) return false;
    if (t.has(e)) return false;
    t.add(e);
    const n = e.lt;
    if (n && markWalk(n, t)) return true;
    // Mid-recompute (the clearStatus companion poke runs before
    // trimStaleDeps), only the validated prefix [_deps.._depsTail] is this
    // pass's dependency set — walking past it would read dropped deps and
    // latch a stale verdict on the companion.
        const i = e;
    const r = i.ie & REACTIVE_RECOMPUTING_DEPS ? i.Ye : undefined;
    if (r !== null) {
        for (let e = i.nt ?? null; e !== null; e = e.it) {
            if (!e.me && markWalk(e.ut, t)) return true;
            if (e === r) break;
        }
    }
    return false;
}

/** Gated entry: apps with no live mark pay one integer compare. */ function markCovered(e) {
    return activeAffectsMarks !== 0 && markWalk(e, new Set);
}

function quietPending(e) {
    if (e.o?.le) {
        for (const t of e.o.le) if (!t.o?.pe) return false;
        return true;
    }
    return e.o?.pe ?? false;
}

// NOTE: a loadingValue node's open loading window (_loading) is verdict-quiet
// on purpose: commit #0 answers the question by declaration, so the window
// reads NOT pending — first-load affordances live in the value channel
// (null / skeleton provenance the author encoded), and isPending stays what
// it always was: refetch truth for an answered question. This keeps the
// verdict fully correlated with transition-class machinery and keeps server
// (always false) and client hydration trivially consistent.
function newQuestionInFlight(e) {
    return !!(e.S & STATUS_PENDING) && !(e.S & STATUS_UNINITIALIZED) && !quietPending(e);
}

function computePendingState(e) {
    const t = e;
    if (t.ie & REACTIVE_DISPOSED) return false;
    // Mark coverage is transitive by dep-graph reachability: a latest() shadow
    // reaches its owner (and a store leaf its firewall) through its own deps,
    // so the one walk covers direct marks, derivation, and companion chains.
        if (markCovered(e)) return true;
    const n = e.lt;
    if (e.o?.Et) {
        const t = e.o?.Et;
        const n = t.lt || t;
        return newQuestionInFlight(n);
    }
    if (n && e.Pe !== NOT_PENDING && !hasActiveOverride(e)) {
        return !!(n.ie & REACTIVE_MANUAL_WRITE) || !n.o?.Ee && !(n.S & STATUS_PENDING) || !!(n.S & STATUS_PENDING) && quietPending(n);
    }
    // `!comp._loading`: a hold created while the loading window is still open is
    // the window's own landing in flight to its commit — verdict-quiet like the
    // rest of the window (the UNINITIALIZED check suppresses exactly this frame
    // for windowless first loads; born-committed nodes need their own gate, #2990).
        if (e.Pe !== NOT_PENDING && !(t.S & STATUS_UNINITIALIZED) && !t.Ie) {
        if (hasActiveOverride(e)) return !e.Ue || !e.Ue(e.Pe, unwrapOverride(e.o?.De));
        return true;
    }
    return newQuestionInFlight(t);
}

function syncCompanions(e, t) {
    if (e.o?.Ge) updatePendingSignal(e);
    if (e.o?.ge) setSignal(e.o?.ge, t);
}

function updatePendingSignal(e) {
    if (e.o?.Ge) {
        setSignal(e.o?.Ge, computePendingState(e));
    }
    if (e.o?.ge) updatePendingSignal(e.o?.ge);
}

function updateChildCompanions(e) {
    const t = e.o?.It;
    if (t === undefined) return;
    for (const e of t) updatePendingSignal(e);
}

/**
 * Re-derive every verdict companion downstream of `el` (subs + firewall
 * children, dedup'd). The affects() channel's poke walk: registration and
 * re-ask flips use the live write path (companion setSignal — its own lane
 * lets the wake escape an incomplete transition's effect stash, #2887);
 * mark release passes `snap` because it runs inside queue finalization,
 * where companion writes must land committed (a setSignal there would open
 * a fresh override window that nothing settles).
 */ function repollDownstreamVerdicts(e, t = false) {
    const n = t ? snapCompanionsToState : updatePendingSignal;
    const i = new Set;
    const visit = e => {
        if (i.has(e)) return;
        i.add(e);
        if (e.o?.Ge || e.o?.ge) n(e);
        for (let t = e.u; t !== null; t = t.ae) visit(t.ce);
        for (let t = e.o?.i ?? null; t !== null; t = t.Se) {
            visit(t);
        }
    };
    visit(e);
}

/**
 * The correction half of the provisional fresh-read suppression (see
 * collectPending): fired from the sanctioned async-registration site
 * (GlobalQueue.notify) when a transaction gains an in-flight async blocker.
 * Every probe that returned "not pending" purely because it read a held
 * value belonging to that transaction re-runs — its re-probe now sees the
 * live blocker through heldAwaitingAsync and lands the true verdict. The
 * wake mirrors a companion write's own notification (optimistic-dirty on the
 * companion's lane) so the corrected verdict commits and flushes immediately
 * instead of being held with the transaction it reports on.
 */ function wakeSuppressedProbes(e) {
    if (suppressedProbes.size === 0) return;
    let t = false;
    for (const [n, i] of suppressedProbes) {
        const r = n._e;
        const s = r ? currentTransition(r) : null;
        if (!s) {
            suppressedProbes.delete(n);
            continue;
        }
        if (s !== e) continue;
        suppressedProbes.delete(n);
        const o = n.o?.Ge?.o?.Be;
        for (const e of i) {
            if (e.ie & REACTIVE_DISPOSED) continue;
            e.ie |= REACTIVE_OPTIMISTIC_DIRTY;
            if (o) assignOrMergeLane(e, o); else if (e.o !== null) e.o.Be = undefined;
            enqueueSub(e);
            t = true;
        }
    }
    if (t) schedule();
}

function snapCompanionsToState(e) {
    suppressedProbes.size !== 0 && suppressedProbes.delete(e);
    const t = e.o?.Ge;
    if (t && (t.o?.De === undefined || t.o?.De === NOT_PENDING)) {
        const n = computePendingState(e);
        if (t.be !== n || t.Pe !== NOT_PENDING) {
            t.be = n;
            t.Pe = NOT_PENDING;
            insertSubs(t);
            schedule();
        }
    }
    const n = e.o?.ge;
    if (n && !(n.ie & REACTIVE_DISPOSED)) {
        if ((n.o?.De === undefined || n.o?.De === NOT_PENDING) && n.Pe === NOT_PENDING && !Object.is(n.be, e.be) && !(n.ie & (REACTIVE_DIRTY | REACTIVE_CHECK))) {
            n.ie |= REACTIVE_DIRTY;
            insertIntoHeap(n, queueFor(n));
            insertSubs(n);
            schedule();
        }
        snapCompanionsToState(n);
    }
}

function getLatestValueComputed(e) {
    let t = e.o?.ge;
    // A shadow disposed while unobserved (its gated reader unmounted at a
    // landing) is a corpse: sync writes into it equality-swallow against its
    // frozen _value, and a later read revives it via recompute — clearing
    // DISPOSED and re-deriving from the committed view, so the banner showed
    // the previous transition's target (#3041 follow-up). Treat it as absent;
    // recreation backfills from the in-flight write below.
        if (t && t.ie & REACTIVE_DISPOSED) t = undefined;
    if (!t) {
        const n = latestReadActive;
        setLatestReadActive(false);
        const i = pendingCheckActive;
        setPendingCheckActive(false);
        const r = context;
        setContextInternal(null);
 // Detach from owner so it isn't disposed with effects
                t = optimisticComputed(() => read(e));
        ext(e).ge = t;
        e.T |= CONFIG_HAS_COMPANIONS;
        markFirewallChildCompanions(e);
        ext(t).Et = e;
 // Parent-child lane relationship
        // Backfill an in-flight write (mirrors getPendingSignal): the companion is
        // created lazily, possibly after the write was processed — syncCompanions
        // only pushes into companions that already exist, so the first latest()
        // read inside a held transition showed the committed value (#3041).
                if (e.Pe !== NOT_PENDING && !hasActiveOverride(e)) setSignal(t, e.Pe);
        setContextInternal(r);
        setPendingCheckActive(i);
        setLatestReadActive(n);
    }
    return t;
}

/** The latest()-mode read path, installed as GlobalQueue._latestRead. */ function latestRead(e) {
    const t = getLatestValueComputed(e);
    const n = latestReadActive;
    setLatestReadActive(false);
    const i = e.o?.De !== undefined && e.o?.De !== NOT_PENDING ? unwrapOverride(e.o?.De) : e.be;
    let r;
    try {
        // An untracked latest() read has no reading context, so read() never
        // performs its mid-tick pull — a plain write queued between two latest()
        // calls left a still-subscribed shadow at its previous speculative value
        // until the flush (#2922). Mirror the tracked-read pull here: mark the
        // queued staleness through the graph, then bring the shadow up to date.
        const e = queueFor(t);
        if (t.Le >= e.xe && !(t.ie & (REACTIVE_DISPOSED | REACTIVE_ZOMBIE))) {
            markHeap(e);
            prepareComputed(t, true);
        }
        r = read(t);
    } catch (t) {
        if (t instanceof NotReadyError && (!context || !(e.S & STATUS_UNINITIALIZED))) return i;
        throw t;
    } finally {
        setLatestReadActive(n);
    }
    if (t.S & STATUS_PENDING) return i;
    if (stale && currentOptimisticLane && t.o?.Be) {
        const e = findLane(t.o?.Be);
        const n = findLane(currentOptimisticLane);
        if (e !== n && e.Ae.size > 0) {
            return i;
        }
    }
    // A shadow recomputed by the pull above (not at creation) holds its fresh
    // speculative value in _pendingValue; a contextless read() only surfaces
    // _value. Overrides stay authoritative (A17), and stale readers keep the
    // other transition's committed view, matching read()'s own selection.
        if (t.Pe !== NOT_PENDING && !hasActiveOverride(t) && !(stale && t._e && activeTransition !== t._e)) return t.Pe;
    return r;
}

/** The isPending()-probe read path, installed as GlobalQueue._pendingCheck. */ function pendingCheckRead(e, t, n, i) {
    setPendingCheckActive(false);
    if (typeof e.oe === "function") prepareComputed(e, true);
    const r = n.S;
    if (t && r & STATUS_PENDING && r & STATUS_UNINITIALIZED) {
        if (tracking && e !== t) link(e, t);
        setPendingCheckActive(true);
        throw n.o?._;
    }
    collectPendingSources(e);
    if (i) collectPendingSources(i);
    setPendingCheckActive(true);
}

/**
 * A held node whose transaction still has an async question in flight. The
 * probe's fresh-read pairing rule (#2831 — "a reader that sees the fresh
 * value must not also be told it is pending") only applies to LANDED answers
 * awaiting reveal; while the answer is still computing, the fresh value the
 * reader saw is an input, and pending remains the truth for every reader
 * (#3028).
 */ function heldAwaitingAsync(e) {
    const t = e._e;
    const n = t ? currentTransition(t) : activeTransition;
    if (!n || n.fn) return false;
    // A plain staged write (a signal/store leaf — no _fn) held while an action
    // is still running is an INPUT to a computation still in flight (#3078):
    // the pairing rule must not suppress the verdict, or a memo recomputing
    // mid-action reads the staged value, gets told "not pending", and
    // disagrees with a direct isPending() probe for the whole action window.
    // A computed's staged value is the opposite case — a LANDED answer
    // awaiting reveal — where the pairing rule stands even inside an open
    // action (#2831: a reader that saw the new value must not also see
    // pending); still-computing answers are covered by the reporter scan.
        if (n.ue.length && !e.oe) return true;
    // A node not yet stamped with a transition only qualifies through the
    // action check above; the reporter scan below is for transition-held
    // writes whose source async is still computing.
        if (!t) return false;
    for (const [e, t] of n.Ne) {
        if (t.size && e.S & STATUS_PENDING && e.o?._?.source === e) return true;
    }
    return false;
}

function recordFreshRead(e, t) {
    if (pendingProbe !== null && e.Pe !== NOT_PENDING && t === e.Pe) {
        if (heldAwaitingAsync(e)) return;
        pendingProbe.freshReads.add(e);
    }
}

function applyReask(e, t) {
    const n = !!(e.S & STATUS_PENDING);
    const i = t && !(n && !e.o?.pe);
    const r = n && (e.o?.pe ?? false) !== i;
    // Allocation-free for the quiet case: false is the extension default.
        if (i) ext(e).pe = true; else if (e.o !== null) e.o.pe = false;
    return r;
}

function latest(e) {
    const t = latestReadActive;
    setLatestReadActive(true);
    try {
        return e();
    } finally {
        setLatestReadActive(t);
    }
}

function isPending(e) {
    const t = pendingCheckActive;
    const n = pendingProbe;
    setPendingCheckActive(true);
    const i = pendingProbe = {
        found: false,
        sources: new Set,
        freshReads: new Set,
        suppressed: []
    };
    const collectPending = () => {
        setPendingCheckActive(false);
        try {
            i.sources.forEach(e => {
                if (read(getPendingSignal(e))) {
                    if (!i.freshReads.has(e)) i.found = true; else i.suppressed.push(e);
                }
            });
        } finally {
            setPendingCheckActive(true);
        }
        // A "not pending" verdict that exists only because this reader saw the
        // fresh held value is provisional: if the write turns out NOT to commit
        // this flush (a downstream async pends and holds it), the suppression was
        // wrong and the wrapper must re-ask (#3028). Remember who to wake — the
        // async registration (GlobalQueue.notify) triggers wakeSuppressedProbes.
                if (!i.found && i.suppressed.length && context && typeof context.oe === "function") {
            for (const e of i.suppressed) {
                let t = suppressedProbes.get(e);
                if (!t) suppressedProbes.set(e, t = new Set);
                t.add(context);
            }
        }
    };
    try {
        e();
        collectPending();
        return i.found;
    } catch (e) {
        collectPending();
        if (e instanceof NotReadyError) {
            const t = !!(e.source?.S & STATUS_UNINITIALIZED);
            if (i.found && !t) return true;
            if (context && t) throw e;
        }
        return i.found;
    } finally {
        setPendingCheckActive(t);
        pendingProbe = n;
    }
}

// Hook installation (same late-binding pattern as GlobalQueue._update /
// _propagateAffects): core call sites fire these behind the same guards the
// direct calls used, so behavior is identical once this module loads.
GlobalQueue.Oe = syncCompanions;

GlobalQueue.de = updatePendingSignal;

GlobalQueue.ye = updateChildCompanions;

GlobalQueue.un = snapCompanionsToState;

GlobalQueue.Pt = latestRead;

GlobalQueue.Dt = pendingCheckRead;

GlobalQueue.Ht = recordFreshRead;

GlobalQueue.Je = applyReask;

GlobalQueue.k = repollDownstreamVerdicts;

GlobalQueue.wt = witnessAffects;

GlobalQueue.jt = wakeSuppressedProbes;

export { isPending, latest };