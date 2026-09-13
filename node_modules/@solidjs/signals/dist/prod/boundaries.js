import { runWithOwner, signal, untrack, read, computed, setSignal, ext, recompute } from "./core/core.js";

import { NotReadyError, unwrapStatusError } from "./core/error.js";

import { createOwner, cleanup } from "./core/owner.js";

import { Queue, haltReactivity, schedule } from "./core/scheduler.js";

import { getContext, setContext, createContext } from "./core/context.js";

import { STATUS_PENDING, STATUS_ERROR, REACTIVE_DISPOSED, CONFIG_AUTO_DISPOSE } from "./core/constants.js";

import "./core/invariants.js";

import "./core/verdict.js";

import "./core/effect.js";

import { accessor } from "./signals.js";

function boundaryComputed(e, t) {
    const r = computed(e, {
        lazy: true
    });
    ext(r).h = (e, t) => {
        // Use passed values if provided, otherwise read from node
        const n = e !== undefined ? e : r.S;
        const s = t !== undefined ? t : r.o?._;
        // Notify both status dimensions like a render effect does; the queue chain
        // consumes this boundary's own type and forwards the remainder upward until
        // a boundary that handles it is found.
                r.S &= ~r.R;
        const i = r.C.notify(r, STATUS_PENDING | STATUS_ERROR, n, s);
        // The queue is the only propagation channel: a foreign status must not stay
        // reader-visible on the tree, or reads re-throw it across the boundary and
        // link unrelated ambient contexts (the #2809 nested-boundary loop). Deps are
        // untouched, so the tree still recomputes when the foreign source settles.
                const o = n & ~r.R & (STATUS_PENDING | STATUS_ERROR);
        if (o) {
            r.S &= ~o;
            if (r.o?._ === s && !(r.S & (STATUS_PENDING | STATUS_ERROR))) if (r.o !== null) r.o._ = undefined;
        }
        // An ERROR the chain could not deliver to any boundary is uncaught. The
        // scrub above already removed it from reader-visible state, so without
        // escalation here it would vanish entirely (#2884) — halt-and-throw,
        // exactly like an unhandled effect error.
                if (!i && n & STATUS_ERROR) {
            haltReactivity(unwrapStatusError(s));
            throw s;
        }
    };
    r.R = t;
    r.T &= ~CONFIG_AUTO_DISPOSE;
    recompute(r, true);
    return r;
}

function createBoundChildren(e, t, r, n) {
    const s = e.C;
    s.addChild(e.C = r);
    cleanup(() => s.removeChild(e.C));
    return runWithOwner(e, () => {
        const e = computed(t);
        return boundaryComputed(() => flatten(read(e)), n);
    });
}

const ON_INIT = Symbol();

const RevealControllerContext = /* @__PURE__ */ createContext(null);

let _revealUsed = false;

const FALSE_ACCESSOR = () => false;

const SEQUENTIAL_ACCESSOR = () => "sequential";

function isRevealController(e) {
    return e instanceof RevealController;
}

function isSlotReady(e) {
    return isRevealController(e) ? e.O() : e.v.size === 0 && !e.U;
}

function isSlotMinimallyReady(e) {
    return isRevealController(e) ? e.I() : isSlotReady(e);
}

function setSlotState(e, t, r, n) {
    setSignal(e.D, r);
    setSignal(e.P, n);
    if (isRevealController(e)) {
        if (!r && e.j === t) e.j = undefined;
        return e.B(r, n);
    }
    if (!r && e.W === t && e.L) e.W = undefined;
}

class RevealController {
    F;
    q;
    V=[];
    j;
    D=signal(false, {
        ownedWrite: true,
        H: true
    });
    P=signal(false, {
        ownedWrite: true,
        H: true
    });
    J=true;
    K=true;
    X=false;
    constructor(e, t) {
        this.F = e;
        this.q = t;
    }
    Y(e) {
        for (let t = 0; t < this.V.length; t++) {
            const r = this.V[t];
            if ((isRevealController(r) ? r.j : r.W) !== this) continue;
            if (e(r) === false) return false;
        }
        return true;
    }
    O() {
        return this.Y(isSlotReady);
    }
    /**
     * "Minimally ready" = this group has something visible to show under its own policy.
     * Used by an enclosing `together` group to decide when it can release.
     * - `together`: every direct slot is minimally ready.
     * - `sequential`: the first owned slot is minimally ready (frontier can advance).
     * - `natural`: any owned slot is minimally ready.
     */    I() {
        const e = untrack(this.F);
        if (e === "together") return this.Y(isSlotMinimallyReady);
        if (e === "natural") {
            let e = false;
            let t = false;
            this.Y(r => {
                e = true;
                if (isSlotMinimallyReady(r)) {
                    t = true;
                    return false;
                }
            });
            return !e || t;
        }
        // sequential: only the first owned slot matters.
                let t = true;
        this.Y(e => {
            t = isSlotMinimallyReady(e);
            return false;
        });
        return t;
    }
    Z(e) {
        if (this.V.includes(e)) return;
        this.V.push(e);
        const t = untrack(this.F);
        setSignal(e.D, true), setSignal(e.P, t === "sequential" ? !!untrack(this.q) : false);
        untrack(() => this.B());
    }
    $(e) {
        const t = this.V.indexOf(e);
        if (t >= 0) this.V.splice(t, 1);
        untrack(() => this.B());
    }
    B(e, t) {
        if (this.X) return;
        this.X = true;
        const r = this.J;
        const n = this.K;
        try {
            const r = e ?? read(this.D), n = untrack(this.F), s = n === "sequential" && !!untrack(this.q), i = t ?? s;
            if (r) {
                // Held by an outer group. Propagate the hold (and whatever collapsed policy
                // the outer asked for) down the whole subtree. Inner order is ignored while
                // held; it resumes once the outer releases us.
                this.Y(e => setSlotState(e, this, true, i));
            } else if (n === "natural") {
                // Each child reveals based on its own readiness. A nested controller slot
                // is released to run its own order locally — we bypass setSlotState for it
                // so the parent backpointer survives for upward readiness notifications.
                this.Y(e => {
                    if (isRevealController(e)) {
                        setSignal(e.P, false);
                        setSignal(e.D, false);
                        e.B(false, false);
                    } else {
                        setSlotState(e, this, !isSlotReady(e), false);
                    }
                });
            } else if (n === "together") {
                // Release when every direct slot is minimally ready (has something to show
                // under its own order). A fully-ready inner together is minimally ready;
                // sequential's first slot being ready is minimally ready; natural having any
                // ready child is minimally ready. This lets `together` guarantee a single
                // cohesive reveal without waiting for every grandchild.
                const e = this.Y(isSlotMinimallyReady);
                this.Y(t => setSlotState(t, this, !e, false));
            } else {
                let e = false;
                this.Y(t => {
                    if (e) return setSlotState(t, this, true, s);
                    if (isSlotReady(t)) return setSlotState(t, this, false, false);
                    e = true;
                    // Frontier slot. For a leaf, holding `_disabled=true` is what keeps its
                    // fallback visible. For a composite, we instead release it so it runs
                    // its own order locally — its leaves will each show their own fallback
                    // until their data lands. Outer still waits on full readiness before
                    // advancing past this slot, and we bypass setSlotState so the parent
                    // backpointer survives for upward readiness notifications.
                                        if (isRevealController(t)) {
                        setSignal(t.P, false);
                        setSignal(t.D, false);
                        t.B(false, false);
                    } else {
                        setSlotState(t, this, true, false);
                    }
                });
            }
        } finally {
            this.J = this.O();
            this.K = this.I();
            this.X = false;
        }
        if (this.j && (r !== this.J || n !== this.K)) this.j.B();
    }
}

class CollectionQueue extends Queue {
    ee;
    v=new Set;
    te;
    U=true;
    D=signal(false, {
        ownedWrite: true,
        H: true
    });
    _;
    P=signal(false, {
        ownedWrite: true,
        H: true
    });
    W;
    L=false;
    re;
    ne=ON_INIT;
    constructor(e) {
        super();
        this.ee = e;
    }
    run(e) {
        if (!e || read(this.D) && (!_revealUsed || read(this.P))) return;
        return super.run(e);
    }
    notify(e, t, r, n) {
        if (!(t & this.ee)) return super.notify(e, t, r, n);
        if (this.L && this.re) {
            const e = untrack(() => {
                try {
                    return this.re();
                } catch {
                    return ON_INIT;
                }
            });
            if (e !== this.ne) {
                this.ne = e;
                this.L = false;
                this.v.clear();
            }
        }
        // Routing is dimension-independent: each boundary consumes only its own
        // status dimension from the mask (`type &= ~collectionType` below) and
        // forwards the remainder up the queue chain. An error inside a `Loading`
        // needs no special rule — the ERROR dimension survives consumption here and
        // reaches the `Errored` that catches it natively, and `flags & collectionType`
        // keeps this boundary from collecting a node that isn't actually pending.
        // Symmetrically, a pending inside an `Errored` forwards on the PENDING
        // dimension, while a status already caught by an inner boundary arrives with
        // its dimension consumed from the mask and is correctly not re-routed
        // (the Loading > Errored > content composition escape, #2856).
                if (this.ee & STATUS_PENDING && this.L) return super.notify(e, t, r, n);
        if (r & this.ee) {
            this.U = true;
            const t = n?.source || e.o?._?.source;
            if (t) {
                const e = this.v.size === 0;
                this.v.add(t);
                if (e) setSignal(this.D, true);
                if (this.ee & STATUS_ERROR) {
                    setSignal(this._, unwrapStatusError(t.o?._));
                }
            }
        }
        t &= ~this.ee;
        return t ? super.notify(e, t, r, n) : true;
    }
    se() {
        for (const e of this.v) {
            // A source with a live affects() mark holds display state for the
            // mark's lifetime (the visual channel): the marked node carries no
            // status of its own, so the count is the liveness test. The release
            // sweep (finalizePureQueue after mark release) re-runs this check.
            if (e.ie & REACTIVE_DISPOSED || !e.o?.t && !(e.S & this.ee) && !(this.ee & STATUS_ERROR && e.S & STATUS_PENDING)) this.v.delete(e);
        }
        if (!this.v.size) {
            if (this.ee & STATUS_PENDING && this.U && !this.L && this.te) {
                this.U = !!(this.te.S & this.ee);
            } else {
                this.U = false;
            }
            if (!this.U) {
                setSignal(this.D, false);
                if (this.re) {
                    try {
                        this.ne = untrack(() => this.re());
                    } catch {
                        /* value not yet committed — _prevOn stays stale, next notify will reset */}
                }
            }
        }
        if (_revealUsed) this.W?.B();
    }
}

function createCollectionBoundary(e, t, r, n) {
    const s = createOwner();
    if (_revealUsed) setContext(RevealControllerContext, null, s);
    const i = new CollectionQueue(e);
    if (e === STATUS_ERROR) i._ = signal(undefined, {
        ownedWrite: true,
        H: true
    });
    if (n) i.re = n;
    const o = i.te = createBoundChildren(s, t, i, e);
    // Prime source tracking so reveal registration sees pending sources.
        untrack(() => {
        let t = false;
        try {
            read(o);
        } catch (e) {
            if (e instanceof NotReadyError) t = true; else throw e;
        }
        i.U = t || !!(o.S & e) || o.o?._ instanceof NotReadyError;
    });
    const l = _revealUsed && e === STATUS_PENDING ? getContext(RevealControllerContext) : null;
    if (l) {
        i.W = l;
        l.Z(i);
        cleanup(() => l.$(i));
    }
    return accessor(computed(() => {
        if (!read(i.D)) {
            const e = read(o);
            if (!untrack(() => read(i.D))) return i.L = true, e;
        }
        // Collapsed reveal slots suppress their own output entirely; the
        // renderer treats the hole as empty, so the cast never leaks to users
        // outside a `createRevealOrder` scope.
                if (_revealUsed && read(i.P)) return undefined;
        return r(i);
    }, 
    // Boundary structure, not a user source: its value is fallback-or-content and
    // legitimately swaps mid-hydration (reveal/resume), so it must never be frozen
    // by snapshot capture. The tree no longer carries foreign status flags, so
    // capture can't rely on PENDING to skip this node the way it used to.
    {
        H: true
    }));
}

/**
 * Lower-level primitive that backs the `<Loading>` flow control. Catches
 * pending async reads inside `fn` and renders `fallback` until they settle.
 *
 * App code should use `<Loading fallback={...}>` instead — reach for this only
 * when authoring custom boundary components.
 *
 * @param fn the tracked subtree
 * @param fallback the fallback shown while async reads in `fn` are unresolved
 * @param options `on` — accessor whose value scopes the boundary; when set,
 *   transitions caused by writes to other reactive sources are *not* caught
 *
 * @example
 * ```tsx
 * // Custom boundary component built on top of the primitive.
 * function MyLoading(props: { fallback: JSX.Element; children: JSX.Element }) {
 *   return createLoadingBoundary(
 *     () => props.children,
 *     () => props.fallback
 *   ) as unknown as JSX.Element;
 * }
 * ```
 */ function createLoadingBoundary(e, t, r) {
    return createCollectionBoundary(STATUS_PENDING, e, () => t(), r?.on);
}

/**
 * Lower-level primitive that backs the `<Errored>` flow control. Catches
 * thrown errors inside `fn` and invokes `fallback(error, reset)` instead.
 * `error` is an accessor for the latest captured error; `reset()` recomputes
 * the failing sources so the boundary can attempt to recover.
 *
 * App code should use `<Errored fallback={...}>` instead — reach for this only
 * when authoring custom boundary components.
 *
 * @example
 * ```tsx
 * // Custom boundary that wraps the primitive and adds telemetry.
 * function TracedErrored(props: { fallback: (e: () => unknown) => JSX.Element; children: JSX.Element }) {
 *   return createErrorBoundary(
 *     () => props.children,
 *     (err, reset) => {
 *       reportError(err());
 *       return props.fallback(err);
 *     }
 *   ) as unknown as JSX.Element;
 * }
 * ```
 */ function createErrorBoundary(e, t) {
    return createCollectionBoundary(STATUS_ERROR, e, e => t(accessor(e._), () => {
        for (const t of e.v) {
            // Non-computed sources (patch-channel registrations under plain
            // owners) are not recomputable — their reset is the record's next
            // transition re-applying the patch (re-audit 2, P1-4).
            if (t.oe !== undefined) recompute(t);
        }
        schedule();
    }));
}

/**
 * Coordinate the reveal timing of sibling loading boundaries.
 *
 * Accepts reactive accessors:
 * - `order`: `"sequential"` (default) | `"together"` | `"natural"`.
 *   - `"sequential"` — classic frontier reveal: siblings reveal in registration order
 *     as each resolves; later siblings stay hidden until earlier ones complete.
 *   - `"together"` — every direct slot stays on its fallback until the whole group
 *     is "minimally ready" (each direct slot has produced its own first visible
 *     content under its own order), then the whole group releases at once.
 *   - `"natural"` — children reveal independently (as each resolves). At the top
 *     level this is a no-op compared to not using `createRevealOrder`; the mode
 *     exists for nesting, where the group registers as a single composite slot to
 *     any enclosing `createRevealOrder`.
 * - `collapsed`: only meaningful when `order === "sequential"`. When set, tail siblings
 *   past the frontier suppress their own fallback output. Ignored under `"together"`
 *   and `"natural"` — those orders have no frontier.
 *
 * Nested `createRevealOrder` groups compose: the inner controller registers as a
 * single slot in the outer controller and is held on its fallbacks until the outer
 * releases that slot. Once released, the inner controller runs its own order locally
 * over anything still pending. There is no opt-out from an outer hold.
 *
 * "Minimally ready" is what an order considers its first visible content:
 * - `sequential` — frontier-0 is minimally ready (leaf: on resolve; nested: via its
 *   own minimal signal).
 * - `together` — every direct slot is minimally ready.
 * - `natural` — any direct slot has visible content (leaves on resolve; nested
 *   composites via their own minimal signal).
 *
 * @example
 * ```ts
 * // Primitive form of `<Reveal>` — coordinate sibling loading boundaries
 * // programmatically. App code uses the JSX `<Reveal>` component instead.
 * // Both options are accessors so they can react to state changes.
 * createRevealOrder(
 *   () => renderSiblings(),
 *   { order: () => mode(), collapsed: () => true }
 * );
 * ```
 */ function createRevealOrder(e, t) {
    _revealUsed = true;
    const r = createOwner();
    const n = getContext(RevealControllerContext);
    const s = t?.order || SEQUENTIAL_ACCESSOR, i = t?.collapsed || FALSE_ACCESSOR;
    const o = new RevealController(s, i);
    setContext(RevealControllerContext, o, r);
    return runWithOwner(r, () => {
        const t = e();
        computed(() => {
            s();
            i();
            o.B();
        });
        if (n) {
            o.j = n;
            n.Z(o);
            cleanup(() => n.$(o));
        }
        return t;
    });
}

/**
 * Resolves a children value to its renderable form: unwraps zero-arg functions
 * (accessors), recursively flattens arrays, and optionally skips
 * non-rendering values (`null`, `undefined`, `true`, `false`, `""`).
 *
 * Used internally by flow components and by the renderer to walk a children
 * tree. App code rarely needs this directly — see `children()` in `solid-js`
 * for the user-facing helper that memoizes the result.
 *
 * @param children value or array of values to flatten
 * @param options
 *   - `skipNonRendered` — drop values that won't render
 *   - `doNotUnwrap` — leave function children as-is (caller will resolve)
 *
 * @example
 * ```ts
 * // Custom renderer walking a children tree manually. Most authors should
 * // use `children()` from solid-js, which memoizes the resolved value.
 * function renderChildren(value: unknown): unknown {
 *   return flatten(value, { skipNonRendered: true });
 * }
 * ```
 */ function flatten(e, t) {
    if (typeof e === "function" && !e.length) {
        if (t?.doNotUnwrap) return e;
        do {
            e = e();
        } while (typeof e === "function" && !e.length);
    }
    if (t?.skipNonRendered && (e == null || e === true || e === false || e === "")) return;
    if (Array.isArray(e)) {
        let r = [];
        if (flattenArray(e, r, t)) {
            return () => {
                let e = [];
                flattenArray(r, e, {
                    ...t,
                    doNotUnwrap: false
                });
                return e;
            };
        }
        return r;
    }
    return e;
}

function flattenArray(e, t = [], r) {
    let n = null;
    let s = false;
    for (let i = 0; i < e.length; i++) {
        try {
            let n = e[i];
            if (typeof n === "function" && !n.length) {
                if (r?.doNotUnwrap) {
                    t.push(n);
                    s = true;
                    continue;
                }
                do {
                    n = n();
                } while (typeof n === "function" && !n.length);
            }
            if (Array.isArray(n)) {
                s = flattenArray(n, t, r);
            } else if (r?.skipNonRendered && (n == null || n === true || n === false || n === "")) {
                // skip
            } else t.push(n);
        } catch (e) {
            if (!(e instanceof NotReadyError)) throw e;
            n = e;
        }
    }
    if (n) throw n;
    return s;
}

export { CollectionQueue, RevealController, createErrorBoundary, createLoadingBoundary, createRevealOrder, flatten };