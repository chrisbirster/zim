const REACTIVE_NONE = 0;

const REACTIVE_CHECK = 1 << 0;

const REACTIVE_DIRTY = 1 << 1;

const REACTIVE_RECOMPUTING_DEPS = 1 << 2;

const REACTIVE_IN_HEAP = 1 << 3;

const REACTIVE_IN_HEAP_HEIGHT = 1 << 4;

const REACTIVE_ZOMBIE = 1 << 5;

const REACTIVE_DISPOSED = 1 << 6;

const REACTIVE_OPTIMISTIC_DIRTY = 1 << 7;

const REACTIVE_SNAPSHOT_STALE = 1 << 8;

const REACTIVE_LAZY = 1 << 9;

const REACTIVE_MANUAL_WRITE = 1 << 10;

/**
 * The pending recompute is a re-ask of the same question: `refresh()` dirtied
 * the node while no tracked input changed value. Cleared whenever a real
 * value-change notification arrives (`insertSubs`), and consumed by
 * `recompute` into the node's `_reask` classification — a quiet (re-ask)
 * pending window does not read as pending (question-scoped pending model).
 */ const REACTIVE_REASK = 1 << 11;

/**
 * A dependency write landed while this subscriber was mid-recompute — a
 * nested pull committed beneath one of its reads (#3037). The heap refuses
 * RECOMPUTING nodes, so recompute's tail consumes this latch and reschedules:
 * values the pass read before the nested commit are stale. Only set for
 * links validated this pass (gen-current): a write to an untouched link is
 * either re-read later in the pass (fresh) or trimmed with it (not a dep).
 */ const REACTIVE_MISSED_WAKE = 1 << 12;

// Static configuration bits packed into Owner/Computed/Signal _config.
const CONFIG_OWNED_WRITE = 1 << 0;

const CONFIG_NO_SNAPSHOT = 1 << 1;

const CONFIG_TRANSPARENT = 1 << 2;

const CONFIG_IN_SNAPSHOT_SCOPE = 1 << 3;

const CONFIG_CHILDREN_FORBIDDEN = 1 << 4;

const CONFIG_AUTO_DISPOSE = 1 << 5;

const CONFIG_SYNC = 1 << 6;

// Presence bits (stage-3 hot-path monomorphism, DESIGN-PATCH-CHANNEL §11b):
// optional per-node slots (_overrideValue, _pendingSignal/_latestValueComputed,
// _snapshotValue, _optimisticLane) are NOT part of every node's hidden class —
// reading a missing property defeats V8's inline caches on the hottest write/
// notify loops. These bits live on the always-present `_config` so hot paths
// pay one monomorphic masked read and only touch the optional field when its
// installer flagged it. Bits are STICKY ("may be set") — the guarded field
// read remains authoritative.
const CONFIG_OPTIMISTIC = 1 << 7;

const CONFIG_HAS_COMPANIONS = 1 << 8;

const CONFIG_HAS_SNAPSHOT = 1 << 9;

const CONFIG_HAS_LANE = 1 << 10;

/** Set on a FIREWALL computed when any of its child signals creates an
 * isPending()/latest() companion. Gates the post-recompute child-companion
 * walk (#3038): a store computed's `_child` chain holds one node per
 * materialized leaf, so walking it unconditionally makes every update cost
 * O(all leaves ever read). Sticky — set at companion creation, never
 * cleared; sync-only apps never set it and never pay the walk. */ const CONFIG_CHILD_COMPANIONS = 1 << 11;

/** Set on a computed when its first firewall child signal is installed
 * (projection machinery). Gates markNode's firewall-children walk with one
 * masked read of the always-present _config — the walk's old `_child` read
 * moved into the cold extension (§12), and an unconditional `_x` deref per
 * marked node measurably taxed the propagation hot path (diamond -22%). */ const CONFIG_FW_CHILDREN = 1 << 12;

const STATUS_PENDING = 1 << 0;

const STATUS_ERROR = 1 << 1;

const STATUS_UNINITIALIZED = 1 << 2;

const EFFECT_RENDER = 1;

const EFFECT_USER = 2;

const EFFECT_TRACKED = 3;

const NOT_PENDING = {};

const NO_SNAPSHOT = {};

/**
 * Stand-in stored in `_overrideValue` for an optimistic write of literal
 * `undefined` (#2898). The slot doubles as the optimistic-node brand
 * (`undefined` = not optimistic, `NOT_PENDING` = at rest), so the raw value
 * would erase the node's optimistic identity: the write turns invisible and
 * follow-up writes route off the optimistic path and commit permanently.
 * Same shape as NO_SNAPSHOT. Sites that surface the override VALUE unwrap
 * via `visibleOverrideValue`; slot identity tests stay raw.
 */ const OVERRIDE_UNDEFINED = {};

/** Unwrap an active override's stored value for surfacing to readers (#2898). */ function unwrapOverride(E) {
    return E === OVERRIDE_UNDEFINED ? undefined : E;
}

const STORE_SNAPSHOT_PROPS = "sp";

const SUPPORTS_PROXY = typeof Proxy === "function";

const defaultContext = {};

/**
 * Brand symbol used by `Refreshable<T>` values (projection stores, async
 * memos) to expose their underlying computation to `refresh()`. Not part of
 * the user-facing API.
 *
 * @internal
 */ const $REFRESH = Symbol("refresh");

export { $REFRESH, CONFIG_AUTO_DISPOSE, CONFIG_CHILDREN_FORBIDDEN, CONFIG_CHILD_COMPANIONS, CONFIG_FW_CHILDREN, CONFIG_HAS_COMPANIONS, CONFIG_HAS_LANE, CONFIG_HAS_SNAPSHOT, CONFIG_IN_SNAPSHOT_SCOPE, CONFIG_NO_SNAPSHOT, CONFIG_OPTIMISTIC, CONFIG_OWNED_WRITE, CONFIG_SYNC, CONFIG_TRANSPARENT, EFFECT_RENDER, EFFECT_TRACKED, EFFECT_USER, NOT_PENDING, NO_SNAPSHOT, OVERRIDE_UNDEFINED, REACTIVE_CHECK, REACTIVE_DIRTY, REACTIVE_DISPOSED, REACTIVE_IN_HEAP, REACTIVE_IN_HEAP_HEIGHT, REACTIVE_LAZY, REACTIVE_MANUAL_WRITE, REACTIVE_MISSED_WAKE, REACTIVE_NONE, REACTIVE_OPTIMISTIC_DIRTY, REACTIVE_REASK, REACTIVE_RECOMPUTING_DEPS, REACTIVE_SNAPSHOT_STALE, REACTIVE_ZOMBIE, STATUS_ERROR, STATUS_PENDING, STATUS_UNINITIALIZED, STORE_SNAPSHOT_PROPS, SUPPORTS_PROXY, defaultContext, unwrapOverride };