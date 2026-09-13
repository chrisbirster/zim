import "./core.js";

import { REACTIVE_IN_HEAP, REACTIVE_IN_HEAP_HEIGHT, EFFECT_TRACKED, EFFECT_USER, REACTIVE_ZOMBIE, REACTIVE_RECOMPUTING_DEPS, REACTIVE_MANUAL_WRITE, REACTIVE_CHECK, REACTIVE_DIRTY, CONFIG_FW_CHILDREN } from "./constants.js";

import { zombieQueue, dirtyQueue } from "./scheduler.js";

/** The queue a node belongs to, picked from its own zombie flag. */ function queueFor(e) {
    return e.ie & REACTIVE_ZOMBIE ? zombieQueue : dirtyQueue;
}

/**
 * Schedule one subscriber to re-run on the next flush: tracked effects bypass
 * the heap and go directly to their effect queue; everything else is inserted
 * into its own (zombie-flag-routed) heap with the `_min` cursor pulled down.
 */ function enqueueSub(e) {
    if (e.Re === EFFECT_TRACKED) {
        const E = e;
        if (!E.Xe) {
            E.Xe = true;
            E.C.enqueue(EFFECT_USER, E.Ut);
        }
        return;
    }
    const E = queueFor(e);
    if (E.xe > e.Le) E.xe = e.Le;
    insertIntoHeap(e, E);
}

function actualInsertIntoHeap(e, E) {
    const t = (e.ke?.Ct ? e.ke.Ot?.Le : e.ke?.Le) ?? -1;
    if (t >= e.Le) e.Le = t + 1;
    const n = e.Le;
    const I = E.eE[n];
    if (I === undefined) E.eE[n] = e; else {
        const E = I.st;
        E.ot = e;
        e.st = E;
        I.st = e;
    }
    if (n > E.EE) E.EE = n;
}

function insertIntoHeap(e, E) {
    let t = e.ie;
    // RECOMPUTING refusals are not always losses: a genuinely missed wake (a
    // write to a link this pass already validated) is latched link-side in
    // insertSubs as REACTIVE_MISSED_WAKE for recompute's tail (#3037).
        if (t & (REACTIVE_IN_HEAP | REACTIVE_RECOMPUTING_DEPS | REACTIVE_MANUAL_WRITE)) return;
    if (t & REACTIVE_CHECK) {
        e.ie = t & -4 | REACTIVE_DIRTY | REACTIVE_IN_HEAP;
    } else {
        e.ie = t | REACTIVE_IN_HEAP;
        // An unmarked node entering a marked heap invalidates the markHeap memo:
        // `_marked` is only reset by runHeap, so a write between two mid-tick
        // pulls (read-time markHeap + updateIfNecessary) would otherwise leave
        // this node unmarked and every downstream pull stale until the next
        // flush (#2922: the second `latest()` returned the first write's value).
                if (E.tE && !(t & REACTIVE_DIRTY)) E.tE = false;
    }
    if (!(t & REACTIVE_IN_HEAP_HEIGHT)) actualInsertIntoHeap(e, E);
}

function insertIntoHeapHeight(e, E) {
    let t = e.ie;
    if (t & (REACTIVE_IN_HEAP | REACTIVE_RECOMPUTING_DEPS | REACTIVE_IN_HEAP_HEIGHT | REACTIVE_MANUAL_WRITE)) return;
    e.ie = t | REACTIVE_IN_HEAP_HEIGHT;
    actualInsertIntoHeap(e, E);
}

function deleteFromHeap(e, E) {
    const t = e.ie;
    if (!(t & (REACTIVE_IN_HEAP | REACTIVE_IN_HEAP_HEIGHT))) return;
    e.ie = t & -25;
    const n = e.Le;
    if (e.st === e) E.eE[n] = undefined; else {
        const t = e.ot;
        const I = E.eE[n];
        const o = t ?? I;
        if (e === I) E.eE[n] = t; else e.st.ot = t;
        o.st = e.st;
    }
    e.st = e;
    e.ot = undefined;
}

function markHeap(e) {
    if (e.tE) return;
    e.tE = true;
    for (let E = 0; E <= e.EE; E++) {
        for (let t = e.eE[E]; t !== undefined; t = t.ot) {
            if (t.ie & REACTIVE_IN_HEAP) markNode(t);
        }
    }
}

function markNode(e, E = REACTIVE_DIRTY) {
    const t = e.ie;
    if ((t & (REACTIVE_CHECK | REACTIVE_DIRTY)) >= E) return;
    e.ie = t & -4 | E;
    for (let E = e.u; E !== null; E = E.ae) {
        markNode(E.ce, REACTIVE_CHECK);
    }
    // Firewall children (projection machinery only): gate the cold-extension
    // deref on the config bit — markNode runs per sub edge per write, and an
    // unconditional _x chase here taxed every propagation (diamond -22%).
        if (e.T & CONFIG_FW_CHILDREN) {
        for (let E = e.o.i; E !== null; E = E.Se) {
            for (let e = E.u; e !== null; e = e.ae) {
                markNode(e.ce, REACTIVE_CHECK);
            }
        }
    }
}

function runHeap(e, E) {
    e.tE = false;
    for (e.xe = 0; e.xe <= e.EE; e.xe++) {
        let t = e.eE[e.xe];
        while (t !== undefined) {
            if (t.ie & REACTIVE_IN_HEAP) E(t); else adjustHeight(t, e);
            t = e.eE[e.xe];
        }
    }
    e.EE = 0;
}

function adjustHeight(e, E) {
    deleteFromHeap(e, E);
    let t = e.Le;
    for (let E = e.nt; E; E = E.it) {
        const e = E.ut;
        const n = e.lt || e;
        if (n.oe && n.Le >= t) t = n.Le + 1;
    }
    if (e.Le !== t) {
        e.Le = t;
        for (let E = e.u; E !== null; E = E.ae) {
            // Route each subscriber by its own zombie flag, mirroring the
            // post-recompute height-adjust path. Inserting into the running `heap`
            // unconditionally can park a zombie in `dirtyQueue` (or a live node in
            // `zombieQueue`), breaking the flag/queue invariant `deleteFromHeap`
            // relies on — the same corruption class as #2759.
            insertIntoHeapHeight(E.ce, queueFor(E.ce));
        }
    }
}

export { deleteFromHeap, enqueueSub, insertIntoHeap, insertIntoHeapHeight, markHeap, markNode, queueFor, runHeap };