import { computed, optimisticComputed, setSignal, optimisticSignal, runWithOwner, setMemo, signal, read, untrack } from "./core/core.js";

import { cleanup, createRoot, getOwner, dispose } from "./core/owner.js";

import { globalQueue, Queue } from "./core/scheduler.js";

import { CONFIG_AUTO_DISPOSE, CONFIG_CHILDREN_FORBIDDEN, EFFECT_USER, $REFRESH } from "./core/constants.js";

import "./core/invariants.js";

import "./core/verdict.js";

import { effect, trackedEffect } from "./core/effect.js";

import { installOptimisticEngine } from "./core/optimistic.js";

/**
 * Low-level reactive-cleanup primitive. Registers a callback that runs when
 * the surrounding owner is disposed.
 *
 * **In 2.0 user code this is rare.** The two cases where you might reach for
 * it have better-shaped tools:
 *
 * - **Component lifecycle (mount/unmount, listeners, intervals):** use
 *   {@link onSettled} and **return** a cleanup function. Setup and teardown
 *   stay paired in one block. This replaces the 1.x `onMount` + `onCleanup`
 *   pairing.
 * - **Cleanup tied to an effect run:** `onCleanup` does not belong in
 *   `createEffect`'s apply phase. If a compute phase genuinely needs per-run
 *   teardown, that's usually a sign the work should be a memo/projection
 *   instead, or moved to `onSettled` if it's lifecycle-shaped.
 *
 * Where `onCleanup` is the right tool is **library / custom-primitive
 * internals** — coordinating disposal inside a `createRoot` body, or wiring
 * cleanup to a captured owner via `runWithOwner` from a custom factory.
 * Application code rarely needs to write any of those shapes directly.
 *
 * Must be called inside an owner. Calling outside an owner is a no-op (with a
 * dev-mode warning).
 *
 * Cannot be used inside `createTrackedEffect` or `onSettled` — return a
 * cleanup function from the callback body instead.
 *
 * @example
 * ```ts
 * // Library shape: thread a resource's disposal into a *captured* owner
 * // from a factory that has no settle-phase setup of its own. `onSettled`
 * // would queue a callback we don't need; `onCleanup` is the leaner
 * // primitive when the only job is "register disposal on this owner".
 * function bindToOwner<T extends { dispose(): void }>(owner: Owner, resource: T): T {
 *   runWithOwner(owner, () => onCleanup(() => resource.dispose()));
 *   return resource;
 * }
 * ```
 */ function onCleanup(e) {
    return cleanup(e);
}

function accessor(e) {
    const t = read.bind(null, e);
    t[$REFRESH] = e;
    return t;
}

function createSignal(e, t) {
    if (typeof e === "function") {
        const n = computed(e, t);
        n.T &= ~CONFIG_AUTO_DISPOSE;
        return [ accessor(n), setMemo.bind(null, n) ];
    }
    const n = signal(e, t);
    return [ accessor(n), setSignal.bind(null, n) ];
}

function createMemo(e, t) {
    return accessor(computed(e, t));
}

function createEffect(e, t, n) {
    effect(e, t.effect || t, t.error, {
        user: true,
        ...n
    });
}

/**
 * Creates a reactive computation that runs during the render phase as DOM elements
 * are created and updated but not necessarily connected.
 *
 * Same compute / effect split as `createEffect`, but scheduled inside the render
 * queue rather than after it. Reach for this only when authoring renderer
 * plumbing (custom DOM bindings, JSX-generated `insert()` / `spread()` calls).
 * App code should use `createEffect`.
 *
 * ```typescript
 * createRenderEffect<T>(compute, effectFn, options?: EffectOptions);
 * ```
 * @param compute a function that receives its previous value and returns a new value used to react on a computation
 * @param effectFn a function that receives the new value and is used to perform side effects
 * @param options `EffectOptions` -- name, defer, schedule, transparent
 *
 * @example
 * ```ts
 * // Custom directive: bind an element's textContent to a reactive source.
 * function bindText(el: HTMLElement, source: () => string) {
 *   createRenderEffect(
 *     () => source(),
 *     value => { el.textContent = value; }
 *   );
 * }
 * ```
 *
 * @description https://docs.solidjs.com/reference/secondary-primitives/create-render-effect
 */ function createRenderEffect(e, t, n) {
    effect(e, t, undefined, n);
}

/**
 * Creates a tracked reactive effect where dependency tracking and side effects happen
 * in the same scope.
 *
 * WARNING: Because tracking and effects happen in the same scope, this primitive
 * may run multiple times for a single change or show tearing (reading inconsistent
 * state). Use only when dynamic subscription patterns require same-scope tracking.
 *
 * The callback runs during the flush itself: writes made inside it are queued
 * into the same flush's continuation and are never visible to the callback's
 * own reads (reads return settled values, as in every effect-phase scope), and
 * `flush()` cannot be called from inside it (dev throws; production is a
 * no-op) — defer with `queueMicrotask(() => flush())` if needed.
 *
 * ```typescript
 * createTrackedEffect(compute, options?: { name?: string });
 * ```
 * @param compute a function that contains reactive reads to track and returns an optional cleanup function to run on disposal or before next execution
 * @param options -- name
 *
 * @example
 * ```ts
 * createTrackedEffect(() => {
 *   const target = focusedNode();
 *   if (!target) return;
 *
 *   const handler = () => log(target.value());
 *   target.on("change", handler);
 *
 *   return () => target.off("change", handler);
 * });
 * ```
 *
 * @description https://docs.solidjs.com/reference/secondary-primitives/create-tracked-effect
 */ function createTrackedEffect(e, t) {
    trackedEffect(e, t);
}

/**
 * Creates a reactive computation that runs after the render phase with flexible tracking.
 *
 * ```typescript
 * const track = createReaction(effectFn, options?: EffectOptions);
 * track(() => { // reactive reads });
 * ```
 * @param effectFn a function (or `EffectBundle`) that is called when tracked function is invalidated
 * @param options `EffectOptions` -- name, defer
 *
 * @example
 * ```ts
 * const [count, setCount] = createSignal(0);
 *
 * const track = createReaction(() => {
 *   console.log("count changed once, re-arm to listen again");
 *   track(() => count()); // re-arm
 * });
 *
 * track(() => count()); // initial arm
 *
 * setCount(1); // logs once, reaction re-armed for next change
 * ```
 *
 * @description https://docs.solidjs.com/reference/secondary-primitives/create-reaction
 */ function createReaction(e, t) {
    let n = undefined;
    cleanup(() => n?.());
    const c = getOwner();
    // The currently armed effect node. `track()` replaces the previous
    // subscription (1.x semantics): without disposing the superseded arm, its
    // sources stayed live (firing the callback for replaced dependencies), each
    // accumulated arm delivered its own fire, and un-fired arms leaked as live
    // effect nodes until the owner disposed (#2861).
        let r;
    return o => {
        if (r) {
            dispose(r);
            r = undefined;
        }
        runWithOwner(c, () => {
            effect(() => (o(), r = getOwner()), t => {
                r = undefined;
                n?.();
                const c = (e.effect || e)?.();
                if (false && c !== undefined && typeof c !== "function") ;
                n = c;
                dispose(t);
            }, e.error, {
                ...false ? {
                    ...t,
                    name: t?.name ?? "effect"
                } : t,
                user: true,
                defer: true
            });
        });
    };
}

/** Delivers effect applies on a microtask instead of queueing them (#2930). */ class MicrotaskQueue extends Queue {
    enqueue(e, t) {
        queueMicrotask(() => t(e));
    }
}

/**
 * Awaits a reactive expression and returns its first fully-settled value as a
 * `Promise`. Pending async reads (`createMemo` returning a promise, etc.) are
 * waited on; once the expression returns synchronously without `NotReadyError`
 * the promise resolves with that value. If the expression settles with an
 * error instead — including an async source that rejects — the promise
 * rejects with it.
 *
 * Must be called *outside* a tracking scope — it doesn't subscribe, it just
 * resolves the current value once.
 *
 * @example
 * ```ts
 * const user = createMemo(() => fetch(`/users/${id()}`).then(r => r.json()));
 *
 * // outside any reactive scope
 * const initial = await resolve(() => user());
 * ```
 *
 * @param fn a reactive expression to resolve
 */ function resolve(e) {
    return new Promise((t, n) => {
        createRoot(c => {
            // Deliver effect applies on a microtask instead of the owner queue: an
            // incomplete transition stashes its effect queues until it settles, but
            // an action yielding this promise is itself what keeps the transition
            // open — the stashed res() deadlocked the action (#2930). The compute
            // still runs in place (under the transaction's view when created inside
            // an action step), and status/boundary notifications keep their normal
            // route through the inherited queue.
            const r = getOwner();
            const o = new MicrotaskQueue;
            o.ke = r.C;
 // notify() forwards up the normal chain
                        r.C = o;
            // A user effect rather than a bare computed: computeds are pull-based and
            // are only re-enqueued when a pending source *resolves* — a rejection just
            // marks them errored, so nothing would re-run and the promise would never
            // settle (#2842). The effect's error channel is notified on rejection.
                        effect(e, e => {
                t(e);
                c();
            }, e => {
                // The error arm already unwraps StatusError (#2840) — `err` is the
                // user's original error, matching what error boundaries expose.
                n(e);
                c();
            }, {
                user: true
            });
        });
    });
}

function createOptimistic(e, t) {
    // Install before the node exists: only engine-installed programs can carry
    // an _overrideValue slot (same runtime-install pattern as
    // GlobalQueue._clearOptimisticStore in createOptimisticStore).
    installOptimisticEngine();
    if (typeof e === "function") {
        const n = optimisticComputed(e, t);
        n.T &= ~CONFIG_AUTO_DISPOSE;
        return [ accessor(n), setSignal.bind(null, n) ];
    }
    const n = optimisticSignal(e, t);
    return [ accessor(n), setSignal.bind(null, n) ];
}

/**
 * Schedules `callback` to run **once** after the reactive graph has fully
 * settled — i.e. once every pending async read inside the current owner has
 * resolved and the queue has flushed. Each call registers a single fire; it
 * does not create an ongoing subscription.
 *
 * The canonical lifecycle primitive in 2.0. Three main usages:
 *
 * - **Component-level setup-and-teardown** *(the most common shape)*: run
 *   setup after the component's first stable render and **return a cleanup
 *   function** to dispose it on owner disposal. This is the replacement for
 *   the 1.x `onMount` + `onCleanup` pairing — setup and teardown live in one
 *   block, and `onCleanup` is no longer the right tool for component
 *   bodies. (`onMount` no longer exists in 2.0.)
 * - **Post-settle "ready" hook:** run once after a component's first stable
 *   render — analytics ping, focus, scroll-into-view, etc. No cleanup needed.
 * - **Inside an event handler:** schedule work to run after the action /
 *   transition triggered by the event has completed.
 *
 * Reactive reads inside the callback are *not* tracked — to react to
 * subsequent settles, register a new `onSettled` each time.
 *
 * The callback runs during the settle flush itself, which gives it the same
 * write semantics as every other effect-phase scope (the effect half of
 * `createEffect`, event handlers):
 *
 * - **Writes** are queued into the same flush's continuation — dependent memos
 *   and effects update before the flush returns — but reads inside the
 *   callback keep returning the settled (pre-write) values. A callback never
 *   observes its own unsettled write. Functional setters still compose:
 *   `set(v => v + 1)` twice increments twice.
 * - **`flush()` cannot be called** from inside the callback — the flush is
 *   already running (dev throws; production is a no-op). To force a drain
 *   after this settle, defer it: `queueMicrotask(() => flush())`.
 *
 * `onCleanup` is **not** allowed inside the callback — return a cleanup
 * function instead. The returned cleanup runs on owner disposal.
 *
 * A cleanup return is only honored when `onSettled` is called from an **owned**
 * scope (e.g. a component body). When it fires out of band from an *unowned*
 * scope — an event handler, a tracked effect, or another `onSettled` — there is
 * no owner lifecycle to bind a cleanup to; returning one is a dev-mode error
 * (and is dropped in production). Use the post-settle/event-handler forms below
 * for one-shot work, and keep setup-with-teardown in an owned scope.
 *
 * @example
 * ```tsx
 * // Component-level setup + teardown — replaces onMount + onCleanup.
 * // Subscribe to an external source on mount, unsubscribe on dispose.
 * function useViewportWidth() {
 *   const [width, setWidth] = createSignal(window.innerWidth);
 *   onSettled(() => {
 *     const onResize = () => setWidth(window.innerWidth);
 *     window.addEventListener("resize", onResize);
 *     return () => window.removeEventListener("resize", onResize);
 *   });
 *   return width;
 * }
 * ```
 *
 * @example
 * ```tsx
 * // Post-settle "ready" hook — no cleanup needed.
 * function Dashboard() {
 *   const data = createMemo(async () => fetchData());
 *
 *   onSettled(() => {
 *     analytics.track("dashboard.ready");
 *   });
 *
 *   return <Loading fallback={<Spinner />}><pre>{data()}</pre></Loading>;
 * }
 * ```
 *
 * @example
 * ```tsx
 * // Event-handler — runs after the action settles.
 * function SaveButton() {
 *   const save = action(function* () {
 *     yield api.save();
 *   });
 *
 *   const handleClick = () => {
 *     save();
 *     onSettled(() => toast("Saved!"));
 *   };
 *
 *   return <button onClick={handleClick}>Save</button>;
 * }
 * ```
 *
 * @param callback Function to run; may return a cleanup function that fires
 *   on owner disposal
 */ function onSettled(e) {
    const t = getOwner();
    t && !(t.T & CONFIG_CHILDREN_FORBIDDEN) ? createTrackedEffect(() => untrack(e), undefined) : globalQueue.enqueue(EFFECT_USER, () => {
        // Unowned, out-of-band fire (no owner, or a children-forbidden one this
        // one-shot must not bind to): a returned cleanup has no lifecycle to
        // attach to. Reject it in dev; in production the return is simply
        // dropped — never bound to an unrelated owner or run eagerly.
        e();
    });
}

export { accessor, createEffect, createMemo, createOptimistic, createReaction, createRenderEffect, createSignal, createTrackedEffect, onCleanup, onSettled, resolve };