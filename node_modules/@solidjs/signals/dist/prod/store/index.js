import "../core/core.js";

import "../core/scheduler.js";

import "../core/invariants.js";

import "../core/verdict.js";

import "../core/effect.js";

import { createStoreNext, deepNext, snapshotNext } from "./next/store.js";

export { storeHasFamily, storeHasOptimisticFamily, storeIsShallow } from "./next/store.js";

import { reconcileNextState } from "./next/reconcile.js";

import { createStoreDerivedNext } from "./next/projection.js";

export { createProjectionNext as createProjection } from "./next/projection.js";

function createStore(e, t, r) {
    if (typeof e === "function") return createStoreDerivedNext(e, t, r);
    return createStoreNext(e, !!t?.shallow);
}

function reconcile(e, t = "id") {
    return r => reconcileNextState(e, r, t);
}

function snapshot(e) {
    return snapshotNext(e);
}

function deep(e) {
    return deepNext(e);
}

export { createStore, deep, reconcile, snapshot };