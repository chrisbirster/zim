import { REACTIVE_DISPOSED, STATUS_ERROR, EFFECT_USER, CONFIG_AUTO_DISPOSE, CONFIG_CHILDREN_FORBIDDEN, EFFECT_TRACKED, EFFECT_RENDER, STATUS_PENDING } from "./constants.js";

import { setEffectStatusNotify, ext, createEffectNode, recompute, computed, staleValues } from "./core.js";

import { unwrapStatusError, StatusError } from "./error.js";

import { GlobalQueue, haltReactivity } from "./scheduler.js";

/**
 * Effects are the leaf nodes of our reactive graph. When their sources change, they are
 * automatically added to the queue of effects to re-execute, which will cause them to fetch their
 * sources and recompute
 */ function effect(t, e, E, f) {
    const r = !!f?.user;
    const R = createEffectNode(t, e, E, r ? EFFECT_USER : EFFECT_RENDER, f);
    recompute(R, true);
    !f?.defer && (R.Re === EFFECT_USER || f?.schedule ? R.C.enqueue(R.Re, runEffect.bind(null, R)) : runEffect(R));
}

function notifyEffectStatus(t, e) {
    // Use passed values if provided, otherwise read from node
    const E = t !== undefined ? t : this.S;
    const f = e !== undefined ? e : this.o?._;
    if (E & STATUS_ERROR) {
        this.C.notify(this, STATUS_PENDING, 0);
        if (this.Re === EFFECT_USER) {
            // The error handler is the error arm of the effect phase (#2840 ruling):
            // queue it like the effect function. It runs in the same imperative,
            // writable scope, throws escalate the same way, and a held transition
            // (or optimistic lane) defers it exactly as it defers the success arm.
            // No payload is queued — the node already carries `_statusFlags`/`_error`,
            // and the runner dispatches on them, so a recovery before the effect
            // phase takes the success arm instead. Blocked forwards (explicit
            // `status` arg without node-state writes) don't queue: the status
            // re-propagates unblocked at commit.
            if (this.S & STATUS_ERROR) {
                this.Xe = true;
                this.C.enqueue(this.Re, this.et ??= runEffect.bind(null, this));
            }
            return;
        }
        if (!this.C.notify(this, STATUS_ERROR, STATUS_ERROR)) {
            haltReactivity(unwrapStatusError(f));
            throw f;
        }
    } else if (this.Re === EFFECT_RENDER) {
        this.C.notify(this, STATUS_PENDING | STATUS_ERROR, E, f);
    }
}

function runEffect(t) {
    if (!t.Xe || t.ie & REACTIVE_DISPOSED) return;
    // Error arm (#2840), user effects only: a compute-phase error that is still
    // the node's settled state at effect time runs the bundle's error handler in
    // this same imperative, writable scope. Unwrap the StatusError used for
    // source tracking — user code gets the error it threw, as boundaries do. No
    // handler: log and keep the system alive (the run was skipped). A handler
    // (or logging) consumes the error; a handler throw falls to the shared
    // catch below and escalates boundary-or-halt like any effect-phase throw.
    // Render effects bypass: their errors route to boundaries synchronously in
    // notifyEffectStatus, and a runner queued by an earlier valueChanged in the
    // same flush must not be hijacked by a later-arriving error status.
        if (t.S & STATUS_ERROR && t.Re === EFFECT_USER) {
        const e = unwrapStatusError(t.o?._);
        t.dt = t.be;
        t.Xe = false;
        try {
            t.St ? t.St(e, () => {
                const e = t.At;
                t.At = undefined;
                e?.();
            }) : console.error(e);
        } catch (e) {
            if (!t.C.notify(t, STATUS_ERROR, STATUS_ERROR)) {
                haltReactivity(e);
                throw e;
            }
        }
        return;
    }
    const e = t.At;
    t.At = undefined;
    try {
        e?.();
        const E = t.Tt(t.be, t.dt);
        if (false && E !== undefined && typeof E !== "function") ;
        // The final cleanup is invoked by disposeChildren at true disposal.
                t.At = E;
    } catch (e) {
        ext(t)._ = new StatusError(t, e);
        t.S |= STATUS_ERROR;
        if (!t.C.notify(t, STATUS_ERROR, STATUS_ERROR)) {
            haltReactivity(e);
            throw e;
        }
    } finally {
        t.dt = t.be;
        t.Xe = false;
    }
}

GlobalQueue.tt = runEffect;

/**
 * Internal tracked effect - bypasses heap, goes directly to effect queue.
 * Runs as a leaf owner: child primitives and onCleanup are forbidden (false throws).
 * Uses stale reads.
 */ function trackedEffect(t, e) {
    const run = () => {
        if (!E.Xe || E.ie & REACTIVE_DISPOSED) return;
        try {
            E.Xe = false;
            recompute(E);
        } finally {}
    };
    const E = computed(() => {
        const e = E.At;
        E.At = undefined;
        e?.();
        const f = staleValues(t);
        E.At = f;
    }, {
        ...e,
        lazy: true
    });
    E.At = undefined;
    E.T = E.T & ~CONFIG_AUTO_DISPOSE | CONFIG_CHILDREN_FORBIDDEN;
    E.Xe = true;
    E.Re = EFFECT_TRACKED;
    // Status dispatch rides the SHARED notifier (statusNotifierOf keys off
    // _type): its error arm is behavior-identical to the closure that used to
    // live here, without the per-node NodeExtension allocation.
        E.Ut = run;
    E.C.enqueue(EFFECT_USER, run);
}

// Install the shared effect status notifier (statusNotifierOf serves it to
// every effect node) — module-scope: any bundle that creates effects
// evaluates this module.
setEffectStatusNotify(notifyEffectStatus);

export { effect, trackedEffect };