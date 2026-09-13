import { globalQueue, activeTransition, currentTransition, schedule, flush } from "./scheduler.js";

import { isThenable } from "./async.js";

import "./core.js";

function restoreTransition(e, r) {
    globalQueue.initTransition(e);
    const t = r();
    flush();
    return t;
}

/**
 * The primitive for mutations: imperative async workflows whose *writes span
 * an async gap* — optimistic write, server round-trip, reconciling write —
 * where intermediate state must not leak and failure must revert cleanly
 * (pair with `createOptimistic` / `createOptimisticStore`).
 *
 * Navigation-shaped updates do not need an action. A plain setter call is
 * enough: reads pull the async, and downstream async computeds hold their
 * previous values per-node until the new ones are ready (`isPending` /
 * `latest` expose the in-flight state). Reach for `action` only when writes
 * happen *after* async work, not merely upstream of it.
 *
 * Framework-level actions (router form actions, server actions) are
 * specializations of this primitive: they are actions in exactly this sense —
 * the same transactional semantics — with form binding, serialization, and
 * submission tracking layered on top. The shared name is deliberate.
 *
 * Wraps a generator function so each invocation runs as a single transaction
 * (a "transition") that batches every signal/store write between yields. The
 * surrounding UI sees one atomic update per yielded step; nothing is committed
 * until the action either completes or the next `yield` resolves.
 *
 * `yield` is the transaction-safe suspension point: the action waits for a
 * yielded promise and re-enters the transaction before running the code after
 * it. A plain `await` does NOT — the runtime has no hook into an async
 * generator's internal await continuations, so writes to fresh signals
 * between an `await` and the next `yield` escape the transaction and commit
 * immediately. `await` is still the ergonomic choice for typed results; just
 * put a bare `yield` before any writes that follow it:
 *
 * ```ts
 * const saved = await api.createTodo(text); // typed result
 * yield; // re-enter the transaction before writing
 * setTodos(t => { ... });
 * ```
 *
 * (For the same reason, don't call `flush()` inside an action body — it
 * drains the transaction mid-step.)
 *
 * Each call returns a `Promise` that resolves with the generator's return
 * value, or rejects if it throws. Pair with `createOptimistic` /
 * `createOptimisticStore` to apply tentative writes that auto-revert if the
 * action fails.
 *
 * @example
 * ```ts
 * const [todos, setTodos] = createOptimisticStore<Todo[]>([]);
 *
 * const addTodo = action(async function* (text: string) {
 *   const tempId = crypto.randomUUID();
 *   setTodos(t => { t.push({ id: tempId, text, pending: true }); }); // optimistic
 *   const saved = await api.createTodo(text); // network round-trip, typed
 *   yield; // re-enter the transaction
 *   setTodos(t => {
 *     const i = t.findIndex(x => x.id === tempId);
 *     if (i >= 0) t[i] = saved;
 *   });
 *   return saved;
 * });
 *
 * await addTodo("buy milk");
 * ```
 */ function action(e) {
    return (...r) => new Promise((t, n) => {
        const i = e(...r);
        globalQueue.initTransition();
        let o = activeTransition;
        o.ue.push(i);
        const done = (e, r, u = false) => {
            o = currentTransition(o);
            const s = o.ue.indexOf(i);
            if (s >= 0) o.ue.splice(s, 1);
            // Re-adopt through initTransition like every other resumption site:
            // a bare setActiveTransition leaves globalQueue._batch as a detached
            // ambient batch, and anything registered before the scheduled flush
            // (held writes on a merging transition, optimistic overrides,
            // affects() marks) lands there with nothing to ever finalize it.
                        globalQueue.initTransition(o);
            schedule();
            u ? n(r) : t(e);
        };
        const step = (e, r) => {
            let t;
            try {
                t = r ? i.throw(e) : i.next(e);
            } catch (e) {
                return done(undefined, e, true);
            }
            // A rejected iterator result (async generators) means the error already
            // escaped the generator body — it is completed, and throwing back in
            // would just reject again forever. Settle instead.
                        if (isThenable(t)) return void t.then(run, e => done(undefined, e, true));
            run(t);
        };
        const run = e => {
            if (e.done) return done(e.value);
            // Thenable assimilation can itself throw synchronously (a `then`
            // getter, or a `then()` method that throws — #2918). Match `await`
            // semantics: the failure is thrown back into the generator at the
            // yield point (catchable there); if uncaught, step()'s guard settles
            // the action so its iterator never leaks in the transition. The
            // settled flag implements A+ 2.3.3.3.4.1: a throw after the thenable
            // already called a callback is ignored.
                        let r = false;
            try {
                if (isThenable(e.value)) return void e.value.then(e => {
                    if (r) return;
                    r = true;
                    restoreTransition(o, () => step(e));
                }, e => {
                    if (r) return;
                    r = true;
                    restoreTransition(o, () => step(e, true));
                });
            } catch (e) {
                if (r) return;
                r = true;
                return void restoreTransition(o, () => step(e, true));
            }
            restoreTransition(o, () => step(e.value));
        };
        step();
    });
}

export { action };