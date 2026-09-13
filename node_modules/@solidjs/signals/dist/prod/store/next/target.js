/**
 * Ownership (first cut, decision 2026-08-16d): one WeakSet of store-owned
 * backings serving both the production identity-skip guard and the false
 * no-mutation oracle.
 */
const ownedRaw = new WeakSet;

/** raw → target. The only raw-keyed lookup; boundary mechanism (O8). */ const storeNextLookup = new WeakMap;

function devAssertNeverUserMutation(e) {
    return;
}

let optHooks = null;

function setOptHooks(e) {
    optHooks = e;
}

/** Sticky descendants flag walk (§6d): reconcile's keyed pruning descends
 * only where subscriptions exist at/below. Nodes AND patches count. */ function markDescendants(e) {
    let t = e;
    while (t && !t.d) {
        t.d = true;
        t = t.u;
    }
}

export { devAssertNeverUserMutation, markDescendants, optHooks, ownedRaw, setOptHooks, storeNextLookup };