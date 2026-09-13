import { NoOwnerError, ContextNotFoundError } from "./error.js";

import { getOwner } from "./owner.js";

/**
 * Context provides a form of dependency injection. It is used to save from needing to pass
 * data as props through intermediate components. This function creates a new context object
 * that can be used with `getContext` and `setContext`.
 *
 * A default value can be provided here which will be used when a specific value is not provided
 * via a `setContext` call.
 */ function createContext(e, t) {
    return {
        id: Symbol(t),
        defaultValue: e
    };
}

/**
 * Low-level owner-targeted context read. The user-facing read API is
 * `useContext` (in `solid-js`), which wraps this primitive. Exposed here for
 * cross-package wiring (e.g. hydration-aware context plumbing).
 *
 * @throws `NoOwnerError` if there's no owner at the time of call.
 * @throws `ContextNotFoundError` if a context value has not been set yet.
 *
 * @internal
 */ function getContext(e, t = getOwner()) {
    if (!t) {
        throw new NoOwnerError;
    }
    const n = hasContext(e, t) ? t.we[e.id] : e.defaultValue;
    if (isUndefined(n)) {
        throw new ContextNotFoundError;
    }
    return n;
}

/**
 * Low-level owner-targeted context write. The user-facing API is
 * `createContext` (in `solid-js`); its provider component wraps this
 * primitive. Exposed here for cross-package wiring.
 *
 * @throws `NoOwnerError` if there's no owner at the time of call.
 *
 * @internal
 */ function setContext(e, t, n = getOwner()) {
    if (!n) {
        throw new NoOwnerError;
    }
    // We're creating a new object to avoid child context values being exposed to parent owners. If
    // we don't do this, everything will be a singleton and all hell will break lose.
        n.we = {
        ...n.we,
        [e.id]: isUndefined(t) ? e.defaultValue : t
    };
}

function hasContext(e, t) {
    return !isUndefined(t?.we[e.id]);
}

function isUndefined(e) {
    return typeof e === "undefined";
}

export { createContext, getContext, setContext };