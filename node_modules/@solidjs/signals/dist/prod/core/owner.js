import { REACTIVE_DISPOSED, CONFIG_AUTO_DISPOSE, REACTIVE_ZOMBIE, REACTIVE_IN_HEAP, REACTIVE_IN_HEAP_HEIGHT, CONFIG_TRANSPARENT, defaultContext } from "./constants.js";

import { context, runWithOwner, pendingCheckActive, latestReadActive, tracking } from "./core.js";

import { clearDeps, unobserved } from "./graph.js";

import { deleteFromHeap, queueFor, insertIntoHeap, insertIntoHeapHeight } from "./heap.js";

import { GlobalQueue, zombieQueue, dirtyQueue, globalQueue } from "./scheduler.js";

const PENDING_OWNER = {};

 // Dummy owner to trigger store's read() path
function markDisposal(e) {
    let t = e.ve;
    while (t) {
        const e = t.ie;
        t.ie = e | REACTIVE_ZOMBIE;
        // migrate height-adjust entries too, not just recompute entries: every
        // `deleteFromHeap` call site picks the queue from the zombie flag, so a
        // node left physically linked in `dirtyQueue` after being zombified gets
        // unlinked from the wrong queue on dispose, corrupting the bucket and
        // livelocking the next `runHeap` that reaches it (#2759)
                if (e & (REACTIVE_IN_HEAP | REACTIVE_IN_HEAP_HEIGHT)) {
            deleteFromHeap(t, e & REACTIVE_ZOMBIE ? zombieQueue : dirtyQueue);
            if (e & REACTIVE_IN_HEAP) insertIntoHeap(t, zombieQueue); else insertIntoHeapHeight(t, zombieQueue);
        }
        markDisposal(t);
        t = t.Ve;
    }
}

function dispose(e) {
    // Direct disposal is death, not dormancy: strip the observation lifecycle
    // so a later read freezes at the last committed value instead of
    // reawakening the node (#3024). The teardown itself (heap removal — a node
    // left queued would be recomputed and resurrected by the next flush (#2983)
    // — dep unlinking, child disposal) is exactly unobserved()'s body; only
    // this flag distinguishes death from dormancy.
    e.T &= ~CONFIG_AUTO_DISPOSE;
    unobserved(e);
}

function disposeChildren(e, t = false, n) {
    const i = e.ie;
    if (i & REACTIVE_DISPOSED) return;
    if (t) {
        e.ie = i | REACTIVE_DISPOSED;
        // Companions are created detached and outlive their owner, but a verdict
        // must not: a disposed source can never settle, so an isPending companion
        // latched `true` here would hold a spinner forever (INV-9, the PR #2845
        // edge). Snap runs after the DISPOSED flag is set so the oracle reads
        // false, and notifies subscribers still watching the companion.
                const t = e;
        if (t.o?.Ge || t.o?.ge) GlobalQueue.un(t);
    }
    if (t && e.oe && e.o !== null) e.o.Ee = null;
    let o = n ? e.o?.qe ?? null : e.ve;
    while (o) {
        const e = o.Ve;
        const t = o;
        // Owner teardown is death regardless of the child's own lifecycle
        // (#3024): strip AUTO_DISPOSE so a post-disposal read freezes at the
        // last committed value instead of reawakening in a torn-down tree.
        // Runs before the recursion so already-dormant children (whose
        // disposeChildren call early-returns on REACTIVE_DISPOSED) die too.
        // Only unobserved()'s own node keeps its dormancy — it is never in
        // this loop; its children are rebuilt fresh on reawaken.
                t.T &= ~CONFIG_AUTO_DISPOSE;
        // Heap removal must not be gated on `_deps`: a dependency-free
        // computation queued by refresh() has a null dep list but still sits in
        // the dirty heap, and left there the post-disposal flush recomputes it —
        // recompute() rewriting `_flags` clears REACTIVE_DISPOSED and the node
        // comes back to life (post-unmount runs, leaked cleanups, #2983).
        // deleteFromHeap self-guards on the in-heap flags (and tolerates plain
        // Owners, whose _flags is undefined), so no gate here.
                deleteFromHeap(t, queueFor(t));
        clearDeps(t);
        disposeChildren(o, true);
        o = e;
    }
    if (n) {
        if (e.o !== null) e.o.qe = null;
    } else {
        e.ve = null;
        e.Me = 0;
    }
    // O(1) splice out of parent's chain on individual dispose. Skipped during
    // batch dispose (parent already disposed) and zombie disposal (node sits on
    // parent's _pendingFirstChild). We leave node._nextSibling intact so outer
    // walks that already advanced past us still reach later siblings.
        if (t && !n && !(i & REACTIVE_ZOMBIE) && e.ke !== null && !(e.ke.ie & REACTIVE_DISPOSED)) {
        const t = e.ct;
        const n = e.Ve;
        if (t !== null) t.Ve = n; else e.ke.ve = n;
        if (n !== null) n.ct = t;
        e.ct = null;
    }
    runDisposal(e, n);
    // Final effect-returned cleanup fires at true disposal, after `_disposal`
    // to mirror rerun ordering (compute-phase teardown first, cleanup last).
        if (t && e.At) {
        const t = e.At;
        e.At = undefined;
        t();
    }
}

function runDisposal(e, t) {
    let n = t ? e.o?.We : e.he;
    if (!n) return;
    if (Array.isArray(n)) {
        for (let e = 0; e < n.length; e++) {
            const t = n[e];
            t.call(t);
        }
    } else {
        n.call(n);
    }
    if (t) {
        if (e.o !== null) e.o.We = null;
    } else e.he = null;
}

function childId(e, t) {
    let n = e;
    while (n.T & CONFIG_TRANSPARENT && n.ke) n = n.ke;
    if (n.id != null) return formatId(n.id, t ? n.Me++ : n.Me);
    throw new Error("");
}

/**
 * Allocates and returns the next stable child id for `owner`. Used by
 * hydration plumbing and `createUniqueId`. Not part of the user-facing API.
 *
 * @internal
 */ function getNextChildId(e) {
    return childId(e, true);
}

/**
 * The id a freshly-created node inherits: an explicit `options.id` wins;
 * transparent nodes share their parent's id; otherwise the parent's next
 * child id is consumed (or `undefined` outside an id-carrying tree).
 */ function inheritId(e, t, n) {
    return e?.id ?? (t ? n?.id : n?.id != null ? getNextChildId(n) : undefined);
}

/**
 * Returns the *next* child id for `owner` without consuming it. Used by
 * hydration plumbing to peek at the id a future child will receive.
 *
 * @internal
 */ function peekNextChildId(e) {
    return childId(e, false);
}

function formatId(e, t) {
    const n = t.toString(36), i = n.length - 1;
    return e + (i ? String.fromCharCode(64 + i) : "") + n;
}

/**
 * Returns the currently-tracking observer (the computation that subscribes to
 * reactive reads at this point), or `null` if reads here would be untracked.
 * Used by reactive primitives that need to know whether they're inside a
 * tracking scope. App code rarely needs this — see `getOwner()` for the
 * lifecycle owner instead.
 *
 * @example
 * ```ts
 * // Library predicate: only register a hot-path subscription when the
 * // caller is inside a tracking scope (memo / effect compute / JSX).
 * function trackIfTracked(source: () => unknown) {
 *   if (getObserver()) source();
 * }
 * ```
 */ function getObserver() {
    if (pendingCheckActive || latestReadActive) return PENDING_OWNER;
    return tracking ? context : null;
}

/**
 * Returns the current reactive **owner** — the lifecycle node that the next
 * `cleanup()` / `onCleanup()` / `createSignal()` etc. will be attached to.
 *
 * Returns `null` if called outside any owner. Capture the owner with
 * `getOwner()` and re-enter it later with `runWithOwner(owner, fn)` to attach
 * disposables created from a callback (event handler, async resolution, etc.)
 * back to a component's lifecycle.
 *
 * @example
 * ```ts
 * function defer<T>(fn: () => T) {
 *   const owner = getOwner();
 *   queueMicrotask(() => runWithOwner(owner, fn));
 * }
 * ```
 */ function getOwner() {
    return context;
}

/**
 * Low-level: registers `fn` as a disposal callback on the current owner.
 * Most code should use `onCleanup()` from `solid-js`, which adds dev-mode
 * checks. `cleanup()` is the unchecked primitive used by internals.
 */ function cleanup(e) {
    if (!context) return e;
    if (!context.he) context.he = e; else if (Array.isArray(context.he)) context.he.push(e); else context.he = [ context.he, e ];
    return e;
}

/**
 * Returns `true` if the owner has been disposed (or marked zombie pending
 * disposal). Pair with a captured owner to bail out of late callbacks whose
 * surrounding component already unmounted.
 *
 * @example
 * ```ts
 * function onSettleSafe(fn: () => void) {
 *   const owner = getOwner();
 *   queueMicrotask(() => {
 *     if (owner && isDisposed(owner)) return; // component unmounted; skip
 *     runWithOwner(owner, fn);
 *   });
 * }
 * ```
 */ function isDisposed(e) {
    return !!(e.ie & (REACTIVE_DISPOSED | REACTIVE_ZOMBIE));
}

function disposeRootSelf(e = true) {
    disposeChildren(this, e);
}

/**
 * Creates a fresh owner attached as a child of the current owner (or as a
 * detached root if there is none). Used by framework internals to group
 * cleanups; app code should use `createRoot()` (host a reactive scope outside
 * a component) or `runWithOwner()` (re-enter a captured owner).
 *
 * @internal
 */ function createOwner(e) {
    const t = context;
    const n = e?.transparent ?? false;
    const i = {
        id: inheritId(e, n, t),
        T: n ? CONFIG_TRANSPARENT : 0,
        Ct: true,
        Ot: t?.Ct ? t.Ot : t,
        ve: null,
        Ve: null,
        ct: null,
        he: null,
        C: t?.C ?? globalQueue,
        we: t?.we || defaultContext,
        Me: 0,
        o: null,
        ke: t,
        dispose: disposeRootSelf
    };
    if (t) {
        const e = t.ve;
        if (e === null) {
            t.ve = i;
        } else {
            i.Ve = e;
            e.ct = i;
            t.ve = i;
        }
    }
    return i;
}

/**
 * Creates a detached reactive root. The callback receives a `dispose()`
 * function which, when called, tears down every signal, memo, effect, and
 * `onCleanup` registered inside the root.
 *
 * Use this to host long-lived reactive scopes outside of a component (custom
 * controllers, app bootstrapping, tests). Inside a component, prefer
 * letting Solid's component lifecycle own things.
 *
 * @example
 * ```ts
 * const dispose = createRoot(dispose => {
 *   const [n, setN] = createSignal(0);
 *   createEffect(() => n(), value => console.log(value));
 *   setInterval(() => setN(x => x + 1), 1000);
 *   return dispose;
 * });
 *
 * // Later, to tear everything down:
 * dispose();
 * ```
 *
 * @description https://docs.solidjs.com/reference/reactive-utilities/create-root
 */ function createRoot(e, t) {
    const n = createOwner(t);
    return runWithOwner(n, () => e(() => n.dispose()));
}

export { cleanup, createOwner, createRoot, dispose, disposeChildren, getNextChildId, getObserver, getOwner, inheritId, isDisposed, markDisposal, peekNextChildId };