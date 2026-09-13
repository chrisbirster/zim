import { computed, suppressComputedRecompute } from "../../core/core.js";

import { getOwner } from "../../core/owner.js";

import { setProjectionWriteActive, projectionWriteActive } from "../../core/scheduler.js";

import { handleAsync } from "../../core/async.js";

import "../../core/verdict.js";

import "../../core/effect.js";

import { CONFIG_AUTO_DISPOSE } from "../../core/constants.js";

import { $TARGET, markRawIngest, STORE_VALUE, setWriteOverride } from "../store.js";

import { reconcileNextState } from "./reconcile.js";

import { wrapNext, storeSetterNext } from "./store.js";

/**
 * Store rewrite — projections (§7/§7b): a projection is a computed store.
 * The derive runs inside a computed whose recompute merges its output into
 * the projection's backing through the adoption channel (replace-mode root:
 * entity changes merge in place, the root proxy is stable for life). Children
 * wrap into the projection's own FAMILY (writes land here, never in a source
 * family), and every family node carries the projection computed as its
 * firewall — reads link the derive's status and lifecycle natively. The §6c
 * status gate in the traps makes an uninitialized async derive's seed
 * unobservable through every read surface.
 *
 * Mirrors the legacy runProjectionComputed shape (shadow runs for open
 * loading windows, handleAsync landings, commit-through-setter) on next
 * primitives; the generic draft write-traps are reused from the legacy
 * module unchanged.
 */
/**
 * Wrap a store proxy as a projection DRAFT: every operation carries the write
 * override (the derive is the author — its ops must not hit the §6c firewall
 * gate, even in a continuation after an `await`/`yield` where the sync write
 * scope has closed).
 *
 * FAKE TARGET, not the store proxy itself (#3060): after a proxy trap
 * returns, the engine runs spec invariant validation against the proxy's
 * TARGET — [[OwnPropertyKeys]] after ownKeys, [[GetOwnProperty]] after
 * set/getOwnPropertyDescriptor/defineProperty. With the store proxy as
 * target those checks re-enter the store's traps OUTSIDE the override
 * bracket (the trap's finally has already run), so `Object.keys(state)` in
 * a derive continuation fired the firewall gate and re-threw the
 * projection's own pending NotReadyError into the derive. A dummy of
 * matching kind (array/object, same trick as the store's own TargetShape)
 * keeps invariant validation away from the store entirely; the traps
 * forward to the closed-over inner proxy inside the bracket.
 *
 * Save/restore projectionWriteActive, never hard-reset: the draft can be
 * driven from inside an enclosing authoritative-write scope (next-store
 * optimistic derives), and a hard `false` would clobber it mid-derive.
 */ function wrapDraft(e, t, r) {
    const i = {
        get(i, o) {
            let n;
            const c = projectionWriteActive;
            setWriteOverride(true);
            setProjectionWriteActive(true);
            try {
                n = e[o];
            } finally {
                setWriteOverride(false);
                setProjectionWriteActive(c);
            }
            if (o === $TARGET) return n;
            return typeof n === "object" && n !== null ? wrapDraft(n, t, r) : n;
        },
        has(t, r) {
            let i;
            const o = projectionWriteActive;
            setWriteOverride(true);
            setProjectionWriteActive(true);
            try {
                i = r in e;
            } finally {
                setWriteOverride(false);
                setProjectionWriteActive(o);
            }
            return i;
        },
        set(i, o, n) {
            if (t && !t()) return true;
            const c = projectionWriteActive;
            setWriteOverride(true);
            setProjectionWriteActive(true);
            try {
                e[o] = n;
                r?.();
            } finally {
                setWriteOverride(false);
                setProjectionWriteActive(c);
            }
            return true;
        },
        deleteProperty(i, o) {
            if (t && !t()) return true;
            const n = projectionWriteActive;
            setWriteOverride(true);
            setProjectionWriteActive(true);
            try {
                delete e[o];
                r?.();
            } finally {
                setWriteOverride(false);
                setProjectionWriteActive(n);
            }
            return true;
        },
        ownKeys() {
            const t = projectionWriteActive;
            setWriteOverride(true);
            setProjectionWriteActive(true);
            try {
                return Reflect.ownKeys(e);
            } finally {
                setWriteOverride(false);
                setProjectionWriteActive(t);
            }
        },
        getOwnPropertyDescriptor(t, r) {
            let i;
            const o = projectionWriteActive;
            setWriteOverride(true);
            setProjectionWriteActive(true);
            try {
                i = Reflect.getOwnPropertyDescriptor(e, r);
            } finally {
                setWriteOverride(false);
                setProjectionWriteActive(o);
            }
            // The dummy target doesn't hold the key, so a non-configurable report
            // would violate the proxy invariant. Store descriptors are already
            // normalized configurable; enforce it for raw leaves too.
                        if (i) i.configurable = true;
            return i;
        },
        defineProperty(i, o, n) {
            if (t && !t()) return true;
            const c = projectionWriteActive;
            setWriteOverride(true);
            setProjectionWriteActive(true);
            try {
                Reflect.defineProperty(e, o, n);
                r?.();
            } finally {
                setWriteOverride(false);
                setProjectionWriteActive(c);
            }
            return true;
        }
    };
    // Matching-kind dummy so Array.isArray(draft) answers like the store.
        return new Proxy(Array.isArray(e) ? [] : {}, i);
}

function createProjectionNextInternal(e, t, r) {
    const i = {
        map: new WeakMap,
        node: null,
        shallow: !!r?.shallow
    };
    const o = wrapNext(t, null, null, i);
    if (i.shallow) {
        // Shallow projection: the root is the only wrapped level — slot values
        // serve raw, ingests sticky raw-mark (same t.s machinery as plain).
        o[$TARGET].s = true;
        markRawIngest(t);
    }
    let n;
    if (r?.seedLoadingValue) n = {
        loadingValue: undefined
    };
    const c = computed(() => {
        if (!i.node) i.node = getOwner();
        runProjectionComputedNext(o, e, r?.key === undefined ? "id" : r.key);
    }, n);
    c.T &= ~CONFIG_AUTO_DISPOSE;
    i.node = c;
    return {
        store: o,
        node: c
    };
}

function createProjectionNext(e, t, r) {
    return createProjectionNextInternal(e, t, r).store;
}

/** Derived writable store (legacy parity): a projection whose public setter
 * masks the recompute for the tick (core R31 — the manual write wins over a
 * same-flush dependency change). */ function createStoreDerivedNext(e, t, r) {
    const {store: i, node: o} = createProjectionNextInternal(e, t, r);
    return [ i, e => {
        // Mark the projection as manually written before notifying nodes.
        suppressComputedRecompute(o);
        storeSetterNext(i, e);
    } ];
}

function runProjectionComputedNext(e, t, r, i, o) {
    const n = getOwner();
    let c = false;
    let s;
    // Open loading window (seedLoadingValue): the observable store IS commit #0
    // for the whole first flight — the derive works a detached shadow of the
    // seed so draft writes cannot tear through to readers (#2988). Every commit
    // point reconciles the shadow through the normal commit path.
        const u = n.Ie ? JSON.parse(JSON.stringify(e[$TARGET][STORE_VALUE])) : null;
    const l = wrapDraft(e, () => !c || n.o?.Ee === s, o);
    storeSetterNext(l, o => {
        s = t(u ?? o);
        c = true;
        const commit = t => {
            // Shadow run: commit a detached snapshot, never the shadow itself
            // (adoption takes the value by identity — handing it the live shadow
            // would fuse the draft to the observable store).
            if (u && (t === undefined || t === u)) t = JSON.parse(JSON.stringify(u));
            if (t === o || t === undefined) return;
            const write = () => storeSetterNext(e, e => reconcileNextState(t, e, r, true), false);
            i ? i(write) : write();
        };
        const l = handleAsync(n, s, commit);
        if (!n.Ie) commit(l);
    }, false);
    return n;
}

export { createProjectionNext, createStoreDerivedNext, runProjectionComputedNext };