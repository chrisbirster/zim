/**
 * Thrown by a tracked read whose value is currently pending (an async memo /
 * `createSignal(asyncFn)` / projection / store derivation that hasn't settled
 * yet). Surfacing through the reactive graph is what suspends the consumer
 * scope — the nearest enclosing `<Loading>` boundary catches the throw and
 * renders its fallback until the source resolves.
 *
 * App code rarely catches this directly; `<Loading>` is the canonical
 * handler. The error type is exposed for advanced cases — e.g. interop layers
 * that bridge Solid's pending-throw protocol to a different async strategy,
 * or tests that want to assert on the suspension shape.
 *
 * @example
 * ```ts
 * // Advanced: distinguish "not ready yet" from a real error in custom
 * // boundary plumbing. App code should rely on `<Loading>` / `<Errored>`.
 * try {
 *   const value = readReactiveSource();
 * } catch (err) {
 *   if (err instanceof NotReadyError) throw err; // re-throw to suspend
 *   reportError(err);
 * }
 * ```
 */
class NotReadyError extends Error {
    source;
    constructor(r) {
        // Control-flow throw: it happens on every read of a pending source, so in
        // production skip V8's eager stack capture (proportional to stack depth —
        // real cost under SSR) by zeroing the V8-specific stackTraceLimit around
        // super(). Dev keeps the stack for debuggability; non-V8 engines (no
        // stackTraceLimit) take the plain path.
        const o = Error;
        const t = o.stackTraceLimit;
        if (t !== undefined) o.stackTraceLimit = 0;
        super();
        if (t !== undefined) o.stackTraceLimit = t;
        this.source = r;
    }
}

class StatusError extends Error {
    source;
    constructor(r, o) {
        super(o instanceof Error ? o.message : String(o), {
            cause: o
        });
        this.source = r;
    }
}

/** Return the user's error from an internal status wrapper. */ function unwrapStatusError(r) {
    return r instanceof StatusError ? r.cause : r;
}

class NoOwnerError extends Error {
    constructor() {
        super("");
    }
}

class ContextNotFoundError extends Error {
    constructor() {
        super("");
    }
}

export { ContextNotFoundError, NoOwnerError, NotReadyError, StatusError, unwrapStatusError };