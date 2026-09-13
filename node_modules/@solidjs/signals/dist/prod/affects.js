import { forEachDependent } from "./core/async.js";

import { ext, statusNotifierOf } from "./core/core.js";

import { $REFRESH, STATUS_PENDING } from "./core/constants.js";

import { NotReadyError } from "./core/error.js";

import { GlobalQueue, globalQueue, schedule, shiftAffectsMarks } from "./core/scheduler.js";

import "./core/verdict.js";

import "./core/effect.js";

import "./core/invariants.js";

import { $TARGET, getStoreAffectsNodes } from "./store/store.js";

/**
 * The counting half of a mark, shared by direct registration and store-scope
 * inheritance (a node created inside a live keyless mark's identity scope).
 * A mark is ONLY this count: coverage of everything derived from the node is
 * pull-derived by the verdict layer's `markWalk` (dep-graph reachability), so
 * nothing is stored downstream and nothing can be stranded or stripped by
 * mid-window recomputes.
 */ function markAffects(e) {
    ext(e).t = (e.o?.t || 0) + 1;
    shiftAffectsMarks(1);
}

/**
 * Boundary visual channel: within a transaction, a live mark holds Loading
 * fallbacks / reveal ordering the way real in-flight async would — but the
 * notification is tagged visibility-only at the source (`_markVisual`), so
 * the root queue never registers reporters from it: marks are invisible to
 * ALL completion and settlement accounting by construction. Boundaries hold
 * the marked node in `_sources` while `_affectsCount` is live; the release
 * sweep (finalizePureQueue re-checks boundary children after mark release)
 * is the display-state update point. Ambient marks release inside the same
 * flush that would surface them, before effects run — verdict-only, netting
 * no visual change.
 */ function notifyMarkBoundaries(e) {
    if (!e.u && !e.o?.i) return;
    const r = new NotReadyError(e);
    r.l = true;
    const t = new Set;
    const visit = e => {
        if (t.has(e)) return;
        t.add(e);
        // Display consumers (render effects, boundary computeds) act on the
        // notification; descent stops there, exactly like the status rails.
                const o = statusNotifierOf(e);
        if (o) {
            o.call(e, STATUS_PENDING, r);
            return;
        }
        forEachDependent(e, visit);
    };
    forEachDependent(e, visit);
}

/**
 * Registers one `affects()` mark on a node: counts it, records the
 * registration with the current transaction (after initTransition the queue's
 * batch IS the active transition, mirroring `_optimisticNodes`), re-derives
 * every downstream verdict companion (the mark channel's only push — verdict
 * pokes, not state), and notifies boundary display state. Both walks run on
 * every registration (not just the first): subscribers gained since an
 * earlier overlapping registration get covered, and dedup stops re-descent.
 */ function registerAffectsMark(e) {
    markAffects(e);
    globalQueue.m.A.push(e);
    // Companions only exist once the verdict layer (isPending/latest) loaded;
    // without them there is no materialized verdict to poke.
        GlobalQueue.k !== null && GlobalQueue.k(e);
    notifyMarkBoundaries(e);
    schedule();
}

/**
 * Releases one registration. When the node's last mark drops, re-derives
 * every downstream verdict through the settlement snap (committed, not
 * transition-scoped — release runs inside queue finalization, where a
 * setSignal would open a fresh override window that nothing settles).
 */ function releaseAffectsMark(e) {
    shiftAffectsMarks(-1);
    e.o.t--;
    if (!e.o.t) {
        GlobalQueue.k !== null && GlobalQueue.k(e, true);
        GlobalQueue.p?.(e);
    }
}

/**
 * Releases one batch of affects marks (a settling transaction's, or the
 * ambient batch at a plain flush end).
 */ function releaseAffectsMarks(e) {
    for (let r = 0; r < e.length; r++) releaseAffectsMark(e[r]);
    e.length = 0;
}

// Late installation (same pattern as `GlobalQueue._update`): the mark engine
// lives with the feature so graphs that never declare a mark never ship it.
// Each call site is gated by state only this module creates (a non-empty
// `_affectsNodes` batch, a live scope in the store's `affectsScopes`), so the
// hooks are installed before the first time any of them can fire.
GlobalQueue.G = releaseAffectsMarks;

GlobalQueue.M = markAffects;

GlobalQueue.N = releaseAffectsMark;

function affects(e, r) {
    const t = e?.[$TARGET];
    if (t) {
        const e = getStoreAffectsNodes(t, r);
        for (let r = 0; r < e.length; r++) registerAffectsMark(e[r]);
        return;
    }
    const o = e?.[$REFRESH];
    if (o) {
        registerAffectsMark(o);
        return;
    }
}

export { affects };