import { unwrapOverride, $REFRESH, CONFIG_OWNED_WRITE, NOT_PENDING, CONFIG_OPTIMISTIC, STATUS_UNINITIALIZED, STATUS_ERROR, CONFIG_CHILDREN_FORBIDDEN } from "../../core/constants.js";

import { setSignal, isEqual, read, pendingCheckActive, latestReadActive, readNodeFast, READ_SLOW, signal, ext, setLatestReadActive, prepareComputed } from "../../core/core.js";

import { projectionWriteActive, setProjectionWriteActive, activeTransition, schedule, currentTransition, setStoreCommitHook } from "../../core/scheduler.js";

import { getObserver, getOwner } from "../../core/owner.js";

import { $TARGET, isWrappable, markRawIngest, $PROXY, getWriteOverride, markRawOne, witnessAffectsMark, $TRACK, affectsScopesLive, inheritAffectsMarks, $AFFECTS, rawValuesUsed, isRawValue, setNextAffectsNodeResolver } from "../store.js";

import { storeNextLookup, optHooks, ownedRaw, markDescendants, devAssertNeverUserMutation } from "./target.js";

import { patchHooks, rowHooks } from "./patch-hooks.js";

/**
 * Store rewrite — increment 2: plain deep stores with pending-backing writes.
 * Contract: INTERNALS-STORE-STATE.md.
 *
 * Write model (RUL-1, unified): the first draft write to a target creates its
 * pending backing `pb` — a descriptor-preserving CoW clone. The draft mutates
 * `pb` natively (array methods, defineProperty, deletes all just work).
 * Reads: drafts and owner-context reads see `pb`; context-free reads see the
 * committed `b` until flush. At flush commit (core's storeCommitHook), each
 * written target folds: diff old `b` vs new backing notifies exactly the
 * changed keys through equality-gated nodes, then `b` becomes the new
 * backing. Setter return-value replacement parks the UNOWNED incoming object
 * in `pb` — adoption: fold swaps it in, ownership resets (2026-08-16c).
 *
 * Nodes carry no pending state — they are pure subscription points; `pb` is
 * the pending home. Laziness: a written target with no subscriptions folds as
 * a pointer swap with zero node work.
 */
// ---------------------------------------------------------------------------
// wrap / dedupe
/** Pre-shaped constructor for OBJECT proxy targets: V8 tips a bare `{}` into
 * dictionary mode once ~19 named properties are assigned onto it (the #3044
 * `ovl`/`del` fields crossed that line — every trap's field read became a
 * hash lookup, a 15% deep-dbmon tick regression). Declaring every field in a
 * constructor pre-allocates in-object slots so the map stays fast, with
 * headroom for future fields. The prototype is reset to `Object.prototype`
 * so proxy-forwarded semantics (getPrototypeOf, constructor) are exactly a
 * plain object's. Array targets keep the bare-`[]` path — they must carry
 * the array exotic class for `Array.isArray(proxy)`.
 *
 * ARRAY SHAPE RULE: arrays normalize their named properties to dictionary
 * mode as the count grows (V8 13.x: counts ≡ 0 mod 3 from 18 up), so the
 * target's named field count is capped at 20 — write-side patch-channel
 * state lives inside the single `pc` extension (see target.ts), never as
 * new named fields here. */
function TargetShape() {
    this.v = undefined;
    this.ch = undefined;
    this.pb = undefined;
    this.n = undefined;
    this.h = undefined;
    this.k = undefined;
    this.dk = undefined;
    this.u = undefined;
    this.pk = undefined;
    this.px = undefined;
    this.d = undefined;
    this.a = undefined;
    this.sc = undefined;
    this.nc = undefined;
    this.adopted = undefined;
    this.fam = undefined;
    this.s = undefined;
    this.ovl = undefined;
    this.del = undefined;
    this.pc = undefined;
    this.hv = undefined;
    this.ht = undefined;
}

TargetShape.prototype = Object.prototype;

/** Lazily allocate the patch-channel extension (one literal shape). */ function pcOf(e) {
    return e.pc ?? (e.pc = {
        sp: null,
        p: null,
        ro: null,
        wk: null,
        qa: null,
        qe: null
    });
}

function createTarget(e, t, n, r = t?.fam ?? null) {
    // The proxy target carries the array exotic class when the value is an
    // array, so Array.isArray(proxy) is true; the fields live on it directly.
    // Direct field assignment in one fixed order (no Object.assign literal
    // copy): every target shares a hidden-class transition chain — createTarget
    // was the #2 store cost in the uibench creation profile.
    const i = Array.isArray(e) ? [] : new TargetShape;
    i.v = e;
    // Chained-backing flag (backing IS another store's proxy, §7b) — cached so
    // the hot read path never does a per-read symbol lookup on the backing.
        i.ch = e[$TARGET] !== undefined;
    i.pb = null;
    i.n = null;
    i.h = null;
    i.k = null;
    i.dk = null;
    i.pc = null;
    i.u = t;
    i.pk = n;
    i.px = null;
    i.d = false;
    i.a = false;
    i.sc = false;
    i.nc = 0;
    i.adopted = false;
    i.fam = r;
    i.s = false;
    i.ovl = false;
    i.del = null;
    i.hv = null;
    i.ht = null;
    i.px = new Proxy(i, traps);
    // Legacy interop: shared machinery (affects walks, wrap dedupe) reads the
    // proxy off looked-up targets as a field.
        i[$PROXY] = i.px;
    (r?.map ?? storeNextLookup).set(e, i);
    return i;
}

function wrapNext(e, t = null, n = null, r = t?.fam ?? null) {
    // markRaw'd values never wrap through ANY store (R42; sticky raw-marking
    // is one half of the never-both-wrapped-and-raw invariant, RUL-12).
    if (rawValuesUsed && isRawValue(e)) return e;
    const i = (r?.map ?? storeNextLookup).get(e);
    if (i !== undefined) return i.px;
    const o = e[$TARGET];
    if (o !== undefined && o.px === e) {
        // Foreign-family proxies re-wrap into THIS family (writes stay isolated);
        // same-family and plain-store proxies pass through.
        if (r === null || o.fam === r) return e;
        return createTarget(e, t, n, r).px;
    }
    return createTarget(e, t, n, r).px;
}

/** Unwrap our own proxies to their current backing; leave everything else. */ function unwrapValue(e) {
    if (e == null || typeof e !== "object") return e;
    const t = e[$TARGET];
    if (t !== undefined && t.px === e && t.v !== undefined) {
        // A draft escaping into other storage must be a REAL container that
        // becomes this target's committed backing at fold (the shared-raw
        // contract) — a prototype overlay is neither.
        if (t.ovl) materializePB(t);
        return t.pb ?? t.v;
    }
    return e;
}

// ---------------------------------------------------------------------------
// nodes: pure subscription points (values used only for equality gating)
function getNode(e, t, n) {
    const r = e.n ??= Object.create(null);
    let i = r[t];
    if (i === undefined) {
        const o = i = signal(n, {
            // Logical-slot equality: values resolving to the same child target
            // are the same slot (privatization/adoption swap raw identity without
            // changing the logical value — only changed leaves notify, R9).
            equals: (t, n) => isEqual(t, n) || sameLogicalSlot(e, t, n),
            unobserved() {
                // A live affects() mark keeps the node addressable (sweep parity).
                if (o.o?.t) return;
                if (e.n && e.n[t] === o) {
                    delete e.n[t];
                    e.nc--;
                }
            }
        }, 
        // Projection nodes carry the projection computed as their firewall:
        // reads through them link the derive's status/lifecycle (§7b).
        e.fam?.node ?? undefined);
        // Store nodes are ownedWrite: the setter carries the owned-scope write
        // guard; node-level setSignals are internal notification machinery.
                o.T |= CONFIG_OWNED_WRITE;
        // Accessor-ness resolved ONCE per node (no per-object descriptor scan):
        // accessor keys serve through Reflect.get with the proxy receiver.
                o.acc = isOwnAccessor(e.pb ?? e.v, t);
        // Wrap cache: the proxy last served for this key and the raw it wrapped.
        // Raw-as-truth stores raw in nodes, so every object read needs a wrapper;
        // one pointer compare (pxv === value) replaces the per-read WeakMap
        // lookup in wrapNext — the dominant read-path cost vs legacy, whose
        // nodes stored pre-wrapped values. A replaced child fails the compare
        // and re-wraps; at most one stale proxy is pinned until the next read.
                o.px = undefined;
        o.pxv = undefined;
        // Optimistic families: arm the override slot — setSignal routes armed
        // nodes through the core engine (lanes, ownership, reverts all native).
                if (e.fam?.opt) {
            ext(o).De = NOT_PENDING;
            o.T |= CONFIG_OPTIMISTIC;
        }
        // A node born inside a live mark's identity scope inherits the mark
        // (the declaration walk could only cover nodes existing then).
                if (t !== $AFFECTS && affectsScopesLive()) inheritAffectsMarks(o, e.v, t);
        r[t] = i;
        e.nc++;
        markDescendants(e);
    }
    return i;
}

function sameLogicalSlot(e, t, n) {
    if (t === null || typeof t !== "object" || n === null || typeof n !== "object") return false;
    const r = e.fam?.map ?? storeNextLookup;
    const i = r.get(t);
    return i !== undefined && i === r.get(n);
}

function getHasNode(e, t, n) {
    const r = e.h ??= Object.create(null);
    let i = r[t];
    if (i === undefined) {
        const o = i = signal(n, {
            equals: isEqual,
            unobserved() {
                if (o.o?.t) return;
                if (e.h && e.h[t] === o) delete e.h[t];
            }
        }, e.fam?.node ?? undefined);
        o.T |= CONFIG_OWNED_WRITE;
        if (e.fam?.opt) {
            ext(o).De = NOT_PENDING;
            o.T |= CONFIG_OPTIMISTIC;
        }
        if (affectsScopesLive()) inheritAffectsMarks(o, e.v, t);
        r[t] = i;
        markDescendants(e);
    }
    return i;
}

function getKeySetNode(e) {
    let t = e.k;
    if (t === null) {
        const n = t = signal(0, {
            equals: false,
            unobserved() {
                if (e.k === n) e.k = null;
            }
        }, e.fam?.node ?? undefined);
        n.T |= CONFIG_OWNED_WRITE;
        if (e.fam?.opt) {
            ext(n).De = NOT_PENDING;
            n.T |= CONFIG_OPTIMISTIC;
        }
        e.k = t;
        markDescendants(e);
    }
    return t;
}

function getDeepNode(e) {
    let t = e.dk;
    if (t === null) {
        const n = t = signal(0, {
            equals: false,
            unobserved() {
                if (e.dk === n) e.dk = null;
            }
        }, e.fam?.node ?? undefined);
        n.T |= CONFIG_OWNED_WRITE;
        if (e.fam?.opt) {
            ext(n).De = NOT_PENDING;
            n.T |= CONFIG_OPTIMISTIC;
        }
        if (affectsScopesLive()) inheritAffectsMarks(n, e.v, $TRACK);
        e.dk = t;
        markDescendants(e);
    }
    return t;
}

/** Deep-witness bump: any value/shape change on a record with a live deep()
 * subscriber notifies it. One null check when unused. */ function bumpDeep(e) {
    if (e.dk !== null) setSignal(e.dk, 1);
}

// ---------------------------------------------------------------------------
// pending backing + fold (the single mutation point)
/** target → committed backing at batch start (the fold diff's old side). */ const foldOlds = new Map;

let hookInstalled = false;

function cloneRaw(e, t) {
    // Descriptor-preserving shallow clone (R29: installed getters stay live;
    // ruled 2026-08-17: frozen sources clone unfrozen — theirs stays frozen).
    // Data descriptors normalize to writable+configurable (the clone is OURS to
    // mutate — R51's "source-non-configurable is writable through the store");
    // enumerability and accessors are preserved. The scan doubles as the
    // accessor-flag detector (free — we're enumerating descriptors anyway).
    const n = Object.getOwnPropertyDescriptors(e);
    for (const r of Reflect.ownKeys(n)) {
        const i = n[r];
        if (r === "length" && Array.isArray(e)) continue;
        i.configurable = true;
        if (!i.get && !i.set) i.writable = true; else if (t) t.a = true;
    }
    return Array.isArray(e) ? Object.defineProperties([], n) : Object.create(Object.getPrototypeOf(e), n);
}

/** Scanned plainness for patch admission (patchableRaw): runs the one-time
 * accessor scan if it hasn't happened yet — the sticky `a` flag alone is not
 * trustworthy before a scan (it starts false and is discovered lazily). */ function targetIsPlain(e) {
    return e.sc ? !e.a : scanAccessorsOnce(e);
}

/** One-time own-accessor scan (Annex-B probes, no descriptor allocation);
 * returns true when the container is plain data (overlay-safe). */ function scanAccessorsOnce(e) {
    const t = e.v;
    for (const n of Reflect.ownKeys(t)) {
        // Own keys shadow prototype accessors, so the lookups are exact here.
        if (lookupGetter.call(t, n) !== undefined || lookupSetter.call(t, n) !== undefined) {
            e.a = true;
            break;
        }
    }
    e.sc = true;
    return !e.a;
}

/** Downgrade a prototype-overlay pending backing to the clone path: builds
 * the real container (committed + overlay writes − deletes) that fold will
 * SWAP in as the committed backing, exactly as if the draft had started on
 * the clone path. Consumers that need a complete container (reconcile's
 * diff walks, drafts escaping into other storage) call this. */ function materializePB(e) {
    if (!e.ovl) return;
    const t = e.pb;
    const n = cloneRaw(e.v, e);
    for (const e of Reflect.ownKeys(t)) {
        const r = Object.getOwnPropertyDescriptor(t, e);
        if (r.get || r.set || !r.enumerable || !r.writable || !r.configurable) Object.defineProperty(n, e, r); else n[e] = r.value;
    }
    if (e.del !== null) {
        for (const t of e.del) delete n[t];
        e.del = null;
    }
    const r = e.fam?.map ?? storeNextLookup;
    r.delete(t);
    ownedRaw.add(n);
    r.set(n, e);
    e.pb = n;
    e.ovl = false;
}

function ensurePB(e) {
    if (activeTransition !== null) foldBatches.set(e, activeTransition);
    let t = e.pb;
    if (t === null) {
        // Prototype-chain overlay (#3044): plain-data non-array containers
        // outside projection/optimistic families open drafts in O(1) — own keys
        // are the writes, reads fall through to committed. Everything else
        // (arrays: splice/length semantics; families: seeding/revert machinery;
        // accessor containers: live getters) keeps the descriptor clone.
        if (e.fam === null && !Array.isArray(e.v) && (e.sc ? !e.a : scanAccessorsOnce(e))) {
            t = e.pb = Object.create(e.v);
            e.ovl = true;
        } else t = e.pb = cloneRaw(e.v, e);
        // Optimistic families: seed USER drafts from the OPTIMISTIC VIEW
        // (committed + active node overrides), so follow-up writes compose on
        // optimism instead of clobbering from base (#2951's compose half).
        // AUTHORITATIVE drafts (projection recompute / write-override landings)
        // seed from committed truth — seeding overrides there would fold a lane
        // value into the committed home ("authority wins at reveal" would break).
                if (e.fam?.opt && !projectionWriteActive && !getWriteOverride()) {
            const n = e.n;
            if (n !== null) {
                for (const e of Reflect.ownKeys(n)) {
                    const r = n[e];
                    if (hasActiveOverride(r)) t[e] = unwrapOverride(r.o?.De);
                }
            }
            const r = e.h;
            if (r !== null) {
                for (const e of Reflect.ownKeys(r)) {
                    const n = r[e];
                    if (hasActiveOverride(n) && !unwrapOverride(n.o?.De)) delete t[e];
                }
            }
        }
        ownedRaw.add(t);
        (e.fam?.map ?? storeNextLookup).set(t, e);
        queueFold(e);
    }
    return t;
}

/** Sentinel holder for `t.ht`: a latest()-pull staged this adoption outside
 * any transition — the hold lasts until the fold commit (drainFolds). */ const PLAIN_HOLD = Symbol("plainHold");

/** True while a latest() read is pulling the projection computed up to date
 * (see the get trap): adoptions landing during the pull are speculative
 * against the un-flushed batch and stage a held view. (Not injectable — the
 * derived createStore overload retains projection machinery in every store
 * bundle, see treeshake.test.ts.) */ let latestPullActive = false;

/** Resolve the held committed view (#3074): answers the masked old backing
 * while the hold is live, and lazily clears a hold whose transition has
 * committed (transitions merge — resolve through currentTransition, same as
 * foldHeld's node stamps). */ function heldMaskView(e) {
    const t = e.ht;
    if (t === null) return null;
    if (t !== PLAIN_HOLD && currentTransition(t)?.fn === true) return e.ht = e.hv = null;
    return e.hv;
}

/**
 * Adoption (2026-08-16c): the incoming object becomes the committed backing
 * IMMEDIATELY — reconcile is eagerly visible to every reader (shipped
 * contract; only its notifications batch), unlike setter writes which stay
 * pending until flush. Ownership resets (incoming is unowned/user data). Any
 * staged draft clone folds into the diff and is discarded — next is the
 * authoritative base (R21/R32).
 */ function adoptPB(e, t, n = false) {
    // Eager mode (plain-store adoption): the caller notifies inline after its
    // descent — no foldOlds queue/drain round trip (the reconcile diff IS the
    // fold diff; ~half of dbmon tick time was this duplication).
    if (!n) {
        queueFold(e);
 // records the pre-batch old before we swap
                e.adopted = true;
        // #3074/#3075: a projection recompute deriving from uncommitted inputs
        // swaps the backing SPECULATIVELY — committed-visibility readers must
        // keep the pre-hold view until the hold resolves (a source held by a
        // live transition, or a latest()-pull ahead of the flush). Post-await
        // landings (write-override) stay immediately visible — landed truth —
        // and clear any hold; optimistic families ride the lane machinery.
                if (e.fam?.opt !== true) {
            if (getWriteOverride()) {
                e.ht = e.hv = null;
            } else if (activeTransition !== null || latestPullActive) {
                if (heldMaskView(e) === null) e.hv = e.v;
                e.ht = activeTransition ?? PLAIN_HOLD;
            }
        }
    }
    e.pb = null;
    // Overlay and accessor-scan state describe the OUTGOING backing — a
    // swapped container must not inherit them: a stale `ovl` beside a nulled
    // pb crashes materializePB (unwrapValue consults ovl before the
    // null-coalesce), a stale `del` would read the adoptee's keys as deleted
    // in the next draft, and a stale plain-data verdict (`sc`/`a`) could
    // admit an accessor-bearing adoptee to the overlay path. Reset; the next
    // draft rescans once (#3044 audit follow-up).
        e.ovl = false;
    e.del = null;
    e.sc = false;
    e.a = false;
    if (e.pc !== null) e.pc.wk = null;
 // adoption supersedes staged trap writes
        e.v = t;
    e.ch = t[$TARGET] !== undefined;
    (e.fam?.map ?? storeNextLookup).set(t, e);
}

/** Sentinel for `t.wk`: the written-keys bound is unusable this batch (an
 * array length write implicitly deleted indices) — consumers full-scan. */ const WK_ALL = new Set;

const plainProto = e => {
    const t = Object.getPrototypeOf(e);
    return t === Object.prototype || t === Array.prototype || t === null;
};

function queueFold(e) {
    if (foldOlds.has(e)) return;
    if (!hookInstalled) {
        hookInstalled = true;
        setStoreCommitHook(drainFolds);
    }
    // Always arm — "map non-empty ⇒ drain scheduled" is NOT an invariant: a
    // held re-queue, or an incomplete-transition flush (which skips
    // commitPendingNodes entirely), leaves entries behind after `scheduled`
    // was consumed. A size-gated arm then strands every LATER fold — queued
    // silently, never drained, committed base frozen at stale state while its
    // nodes commit (#3089). schedule() early-returns when already armed.
        schedule();
    foldOlds.set(e, e.v);
}

/** Fold write-attribution (#3089): a draft written while a transition is
 * active belongs to that transition — its fold must not commit before the
 * transition settles. Observed keys already defer through the held check in
 * drainFolds (their nodes carry _pendingValue); this write-time stamp is the
 * equivalent hold for UNOBSERVED keys, which have no node to consult.
 * Refreshed on every write; resolved through currentTransition at drain
 * (transitions merge — same rule as heldMaskView). */ const foldBatches = new WeakMap;

/** Committed-time privatization for parent-chain slot updates (path copying). */ function privatizeCommitted(e) {
    if (ownedRaw.has(e.v)) return;
    const t = cloneRaw(e.v, e);
    ownedRaw.add(t);
    storeNextLookup.set(t, e);
    e.v = t;
    e.ch = false;
    if (e.u) {
        privatizeCommitted(e.u);
        devAssertNeverUserMutation(e.u.v);
        e.u.v[e.pk] = e.v;
    }
}

function drainFolds() {
    if (foldOlds.size === 0) return;
    const e = [ ...foldOlds ];
    foldOlds.clear();
    for (const [t, n] of e) {
        // A latest()-pull staging holds only until the fold commit: this flush
        // is committing the batch the pull ran ahead of. Transition holds stay —
        // they clear when their transition is done (heldMaskView).
        if (t.ht === PLAIN_HOLD) t.ht = t.hv = null;
        // Eager (write-override) family folds swap pb -> v at notifyWrites'
        // tail: by the time this drain runs they carry no pb, and their
        // structural ops must emit at the fold-commit site below (the clone
        // branch never sees them). Re-audit blocker 4.
                const e = t.pb === null;
        if (t.pb !== null) {
            // #3089: a fold written under a still-running transition defers to
            // that transition's settle (the write-time stamp covers unobserved
            // keys; observed keys also hit the pending-node held check below).
            const e = foldBatches.get(t);
            if (e !== undefined) {
                if (currentTransition(e).fn === false) {
                    foldOlds.set(t, n);
                    continue;
                }
                foldBatches.delete(t);
            }
            // Setter path: nodes were setSignal'd at setter exit (write-time
            // notification — transitions/holds ride core machinery). Commit the
            // backing only for keys whose nodes have committed; a still-pending
            // node (transition-held) re-queues the target for the settling flush.
                        let r = false;
            const i = t.pb;
            const o = t.n;
            if (o !== null) {
                // Only written keys can hold (their nodes took the setSignal); the
                // wk bound keeps this O(written) — see notifyWrites. Same fallback
                // rules as the notify (WK_ALL / accessors / non-plain prototypes).
                const e = t.pc !== null ? t.pc.wk : null;
                const n = e === null || e === WK_ALL || t.a === true || 
                // Overlay pbs chain to the COMMITTED object (#3044) — plainness is
                // the committed container's prototype, not the overlay's.
                !plainProto(t.ovl ? t.v : i) ? Reflect.ownKeys(o) : e;
                for (const e of n) {
                    const t = o[e];
                    if (t !== undefined && t.Pe !== NOT_PENDING) {
                        r = true;
                        break;
                    }
                }
            }
            if (r) {
                foldOlds.set(t, n);
 // re-queue: commit happens when the hold settles
                                continue;
            }
            if (t.ovl) {
                // Overlay flatten (#3044): apply this batch's writes onto an OWNED
                // committed backing in place — O(written), not O(container). The
                // backing keeps its identity, so the `t.v === old` gate below skips
                // path copying (the parent slot already points here) and the
                // adopted-notify (setter notifications happened at write time).
                // Unowned backings privatize first (clone once, parents re-slotted)
                // — the never-mutate-user-data contract holds.
                privatizeCommitted(t);
                const e = t.v;
                for (const t of Reflect.ownKeys(i)) {
                    const n = Object.getOwnPropertyDescriptor(i, t);
                    if (n.get || n.set || !n.enumerable || !n.writable || !n.configurable) Object.defineProperty(e, t, n); else e[t] = n.value;
                }
                if (t.del !== null) {
                    for (const n of t.del) delete e[n];
                    t.del = null;
                }
                (t.fam?.map ?? storeNextLookup).delete(i);
                t.pb = null;
                t.ovl = false;
                if (t.pc !== null) t.pc.wk = null;
 // written-keys window closes with the fold commit
                        } else {
                // Setter-channel structural ops: a fold that changes an array's shape
                // (push/splice/permutation through the setter — the reconcile walk
                // never queues here) is a structural visibility transition for any
                // registered list driver. Identity-keyed; aligned folds emit nothing.
                // Family targets defer to their own adoption emission (fam reconcile).
                // Arrays always fold on this clone branch (overlay is non-array only).
                // Family setter drafts (writable projection push/splice through the
                // masked setter) fold on this branch too and the fold IS their
                // visibility moment — emit unless the structure already rode another
                // channel: adoption folds (reconcile walk emitted ops) and
                // optimistic families (lane-timed override channel). Re-audit
                // blocker 4.
                if (t.pc !== null && t.pc.ro !== null && !t.adopted && t.fam?.opt !== true && Array.isArray(i) && Array.isArray(t.v)) rowHooks.emitSetterRowOps(t, t.v, i);
                t.v = i;
                t.ch = false;
 // pb is always a plain clone
                                t.pb = null;
                if (t.pc !== null) t.pc.wk = null;
 // written-keys window closes with the fold commit
                        }
        }
        if (t.v === n) {
            // A no-op adoption (A -> B -> A before flush) still consumed its walk:
            // clear the flag or every later setter row-op gate (!t.adopted) stays
            // failed and a driven family list freezes (re-audit 5, P1-1).
            t.adopted = false;
            continue;
        }
        // Patch channel (fold-commit site): family targets emit HERE — the fold
        // IS their visibility moment (held folds re-queued above emit when they
        // actually commit) — and so do PLAIN fold-adopted targets (setter-
        // returned root replacements, chained-store swaps: adoptions WITHOUT a
        // reconcile walk, so no walk-site emission ever happened — re-audit 2,
        // P1-2). Plain eager targets emitted at their walk/setter sites already.
                if (t.pc !== null && (t.fam !== null || t.adopted)) {
            // Structural ops for folds whose structure rode no other channel:
            // eager-folded family SETTER drafts (write-override swaps pb -> v at
            // notifyWrites' tail — the clone branch never sees them; adoption
            // folds re-emitting would double the walk's ops) and PLAIN fold
            // adoptions (no walk at all). Optimistic families ride the override
            // channel (lane-timed ops + revert RESYNC) — never re-emit here.
            if (t.pc.ro !== null && t.fam?.opt !== true && (t.fam !== null ? e && !t.adopted : t.adopted) && Array.isArray(t.v) && Array.isArray(n)) rowHooks.emitSetterRowOps(t, n, t.v);
            if (t.pc.p !== null) {
                // Accessor demotion at the fold-commit seam is DEV-ONLY (see the
                // reconcile seam note: prod never pays per-adoption scans).
                patchHooks.emitPatchLocal(t, t.v, n);
            }
        }
        // Path copying (CAS: see the eager-fold twin above).
                if (t.u && t.u.v[t.pk] === n) {
            privatizeCommitted(t.u);
            devAssertNeverUserMutation(t.u.v);
            t.u.v[t.pk] = t.v;
        }
        if (t.adopted) {
            t.adopted = false;
            notifyFold(t, n, t.v);
        }
    }
}

/**
 * Setter-exit notification (write channel): diff the draft's pending backing
 * against committed and setSignal every changed OBSERVED key — write-time
 * notification with commit deferred to node commit, so transition holds,
 * isPending, affects, and lane machinery ride the core natively (§3's
 * "pending home = the node when a node exists"). Unobserved keys stay in the
 * pending backing and fold directly at commit.
 */ function notifyWrites(e) {
    let t = e.pb;
    if (t === null) return;
    // Optimistic channel: user writes on an optimistic family become node-level
    // engine writes (armed nodes route setSignal through optimisticWrite) — the
    // committed backing is NEVER touched; the draft clone is discarded. Reverts,
    // per-transaction ownership, and flash-at-flush are all core-native.
    // Projection recompute writes (projectionWriteActive) and projection draft
    // writes (write-override, incl. post-await async landings) are
    // authoritative and take the plain channel below (they commit silently
    // under overrides per the engine's no-revert-stash contract).
        if (e.fam?.opt) {
        if (!projectionWriteActive && !getWriteOverride()) {
            optHooks.notifyOptimisticWrites(e, t);
            return;
        }
        // Authoritative path on an optimistic family: armed nodes must commit
        // silently (engine bypass) — without this, a landing's setSignals would
        // create lanes and block their own transition's settle.
                if (!projectionWriteActive) {
            setProjectionWriteActive(true);
            try {
                notifyWrites(e);
            } finally {
                setProjectionWriteActive(false);
            }
            return;
        }
    }
    const n = e.v;
    const r = e.n;
    // Written-keys bound: trap writes record their keys, so the notify visits
    // O(written) nodes instead of every subscription on the record (a selection
    // map with thousands of per-key subscribers pays two visits per select,
    // not a full scan). Falls back to the full node scan when the bound can't
    // hold: no trap granularity (wk null), an array length write (WK_ALL —
    // implicit index deletes), accessors on the record (t.a — a getter node's
    // value can change when ANY key is written), or a non-plain prototype
    // (class instances: prototype getters derive from arbitrary fields).
        const i = e.pc !== null ? e.pc.wk : null;
    // Overlay pbs chain to the COMMITTED object (#3044): a prototype-overlay
    // draft is plain data on its own layer, but its getPrototypeOf is the
    // committed container — judge plainness by the COMMITTED prototype or the
    // bound never engages for overlay writes (every plain-object setter batch
    // would full-scan: the exact selection-map workload wk exists for; jf
    // `select` regressed 2x on this).
        const o = i === WK_ALL || e.a === true || !plainProto(e.ovl ? e.v : t) ? null : i;
    if (r !== null) {
        const i = o ?? Reflect.ownKeys(r);
        for (const o of i) {
            const i = r[o];
            if (i === undefined) continue;
            // Per-key accessor handling: the node's cached flag plus ONE getter
            // probe on the incoming side (getters arriving via merge/adoption).
            // Setter-only props read as data (value undefined) so lookupSetter is
            // not consulted on this hot path; prototype getters never own nodes.
                        if (i.acc === true || hasOwn.call(t, o) && lookupGetter.call(t, o) !== undefined) {
                i.acc = isOwnAccessor(t, o);
                const e = Object.getOwnPropertyDescriptor(n, o);
                const r = Object.getOwnPropertyDescriptor(t, o);
                if (e && (e.get || e.set) || r && (r.get || r.set)) {
                    if (e?.get !== r?.get || e?.set !== r?.set || e?.value !== r?.value) setSignal(i, () => FORCE);
                    continue;
                }
                if (!isEqual(e?.value, r?.value)) setSignal(i, () => r?.value);
                continue;
            }
            // No old-side pre-compare: t.v lags across multi-batch windows (a
            // projection recompute can run before the prior fold commits) — the
            // node's OWN current value is the true old side, and setSignal's
            // internal equality already checks exactly that.
                        const f = e.del !== null && e.del.has(o) ? undefined : t[o];
            setSignal(i, () => f);
        }
    }
    const f = e.h;
    if (f !== null) {
        const n = o ?? Reflect.ownKeys(f);
        for (const r of n) {
            const n = f[r];
            if (n !== undefined) setSignal(n, r in t && !(e.del !== null && e.del.has(r)));
        }
    }
    // Deep-witness (dk): setter writes must notify a deep() subscriber even on
    // keys with no node. O(written/pb keys) equality only when a witness exists.
        if (e.dk !== null) {
        if (e.del !== null && e.del.size !== 0) bumpDeep(e); else for (const r of o ?? Reflect.ownKeys(t)) {
            const i = t[r];
            const o = n[r];
            if (i !== null && typeof i === "object" ? !targetsEqual(o, i) : !isEqual(o, i)) {
                bumpDeep(e);
                break;
            }
        }
    }
    if (e.k !== null) {
        let r;
        if (e.ovl) {
            // Overlay membership: only NEW own keys or deletes can change it.
            r = e.del !== null && e.del.size !== 0;
            if (!r) {
                for (const e of Reflect.ownKeys(t)) {
                    if (!hasOwn.call(n, e)) {
                        r = true;
                        break;
                    }
                }
            }
        } else {
            r = Array.isArray(t) && Array.isArray(n) ? arrayStructureChanged(n, t) : membershipChanged(n, t);
        }
        if (r) setSignal(e.k, e => e + 1);
    }
    // Patch channel (setter site): a committed write transitions this record —
    // queue its patches and bubble to ancestors (targeted nested writes must
    // reach the row patch, §4b). One number compare when no patches exist.
    // Family targets skip this site: their visibility moment is the FOLD
    // commit (drainFolds emits), not the recompute/draft write.
        if (e.fam === null && patchHooks !== null && patchHooks.hasPatches()) patchHooks.emitPatch(e, t, n);
    // Projection backing folds split by channel (two pinned contracts):
    // - sync-derive drafts (recompute body): NEVER eager — a downstream async
    //   hold can form LATER in the same flush and the leaf must stay at stale
    //   committed for context-free readers (spec-async "pends only the written
    //   leaf"). drainFolds commits when held-ness is knowable.
    // - post-await async LANDINGS (write-override per-op, microtask context —
    //   no enclosing flush can capture them): the data-level commit is
    //   IMMEDIATE — landed truth shows to untracked readers even while a
    //   downstream consumer's own async still holds the effect-level reveal
    //   (spec-async "verdicts never inherit consumers' in-flight state").
        if (e.fam !== null && e.pb !== null && getWriteOverride()) {
        // Landed truth (post-await write-override): immediately visible to every
        // reader — any staged held view is superseded.
        if (e.ht !== null) e.ht = e.hv = null;
        const n = e.v;
        e.pb = null;
        e.v = t;
        e.ch = false;
        if (e.u && e.u.v[e.pk] === n) {
            privatizeCommitted(e.u);
            devAssertNeverUserMutation(e.u.v);
            e.u.v[e.pk] = t;
        }
    }
}

const FORCE = Symbol();

/** Same logical slot: both values resolve to one (re-pointed) child target —
 * adoption preserved identity, so the slot did not change (R9). */ function targetsEqual(e, t) {
    if (e === null || typeof e !== "object") return false;
    const n = storeNextLookup.get(e);
    return n !== undefined && n === storeNextLookup.get(t);
}

function arrayStructureChanged(e, t) {
    if (e.length !== t.length) return true;
    for (let n = 0; n < t.length; n++) {
        const r = e[n];
        const i = t[n];
        if (!isEqual(r, i) && !targetsEqual(r, i)) return true;
    }
    return false;
}

function membershipChanged(e, t) {
    const n = Reflect.ownKeys(t);
    if (Reflect.ownKeys(e).length !== n.length) return true;
    for (const t of n) if (!(t in e)) return true;
    return false;
}

/**
 * The fold diff walks SUBSCRIPTION KEYS ONLY (legacy parity: `for key in
 * nodes`): nodes exist exactly where something tracked, so unobserved data
 * costs nothing here regardless of object size. Accessor safety rides the
 * sticky `t.a` flag — a node's key was necessarily read, so the get trap has
 * already seen whether it is an accessor.
 */
/** One node's fold notification (shared by notifyFold's walk and the fused
 * adoption walk): accessor-aware compare + equality/identity-gated setSignal. */ function notifyKeyDiff(e, t, n, r, 
// The incoming-side getter probe covers SETTER-channel arrivals (return-
// form merges, defineProperty) — those flow through notifyWrites/
// notifyFold, which probe. The RECONCILE channel (fused walk) passes
// false: reconcile adopts immutable data by contract (R2a) and the pinned
// getter-preservation tests are all setter-channel; skipping ~2 Annex-B
// calls per key per tick is a measured dbmon win.
i = true) {
    if (e.acc === true || i && hasOwn.call(r, t) && lookupGetter.call(r, t) !== undefined) {
        e.acc = isOwnAccessor(r, t);
        const i = Object.getOwnPropertyDescriptor(n, t);
        const o = Object.getOwnPropertyDescriptor(r, t);
        if (i && (i.get || i.set) || o && (o.get || o.set)) {
            // Accessor involved: never invoke; force-notify on shape change so
            // subscribers re-read (and re-track) through the trap.
            if (i?.get !== o?.get || i?.set !== o?.set || i?.value !== o?.value) setSignal(e, () => FORCE);
            return;
        }
        const f = i?.value;
        const l = o?.value;
        if (!isEqual(f, l) && !targetsEqual(f, l)) setSignal(e, typeof l === "function" ? () => l : l);
    } else {
        const i = n[t];
        const o = r[t];
        // Direct value write when not a function (setSignal treats functions as
        // updaters) — saves a closure allocation per changed key on the fold
        // hot path.
                if (!isEqual(i, o) && !targetsEqual(i, o)) setSignal(e, typeof o === "function" ? () => o : o);
    }
}

/** Accessor-flag probe for the fused walk's early-continue (accessor keys
 * can never identity-skip: their VALUE is the descriptor's product). */ function hasAccessorFlag(e) {
    return e.acc === true;
}

/** Fused-walk per-key notification with values already in hand: the caller
 * fetched both sides and handled the identity skip; this applies the
 * accessor branch (cached flag only — reconcile channel) or the plain
 * equality/identity-gated write. */ function notifyKeyValue(e, t, n, r, i, o) {
    if (e.acc === true) {
        notifyKeyDiff(e, t, i, o, false);
        return;
    }
    // The pre-compare is NOT redundant with the node's equals: setSignal parks
    // a pending value and registers with the batch before equality applies at
    // commit (RUL-1), so identity-preserved slots (adopted child containers —
    // every row's fresh `queries` array) must be gated out HERE or each one
    // pays the full write machinery every tick (measured: +0.5ms/tick dbmon).
        if (!isEqual(n, r) && !targetsEqual(n, r)) setSignal(e, typeof r === "function" ? () => r : r);
}

/** Presence + membership halves of a fold notification (shared tail). */ function notifyFoldTail(e, t, n) {
    const r = e.h;
    if (r !== null) {
        for (const e of Reflect.ownKeys(r)) setSignal(r[e], e in n);
    }
    if (e.k !== null) {
        const r = Array.isArray(n) && Array.isArray(t) ? arrayStructureChanged(t, n) : membershipChanged(t, n);
        if (r) setSignal(e.k, e => e + 1);
    }
}

function notifyFold(e, t, n) {
    if (e.dk !== null && t !== n) bumpDeep(e);
    // Optimistic targets: adoption notifications are authoritative landings —
    // bypass the engine (commit into _value; active overrides keep shadowing
    // until their transaction settles, per the no-revert-stash contract).
        if (e.fam?.opt && !projectionWriteActive) {
        setProjectionWriteActive(true);
        try {
            notifyFold(e, t, n);
        } finally {
            setProjectionWriteActive(false);
        }
        return;
    }
    const r = e.n;
    if (r !== null) {
        for (const e of Reflect.ownKeys(r)) {
            notifyKeyDiff(r[e], e, t, n);
        }
    }
    const i = e.h;
    if (i !== null) {
        for (const e of Reflect.ownKeys(i)) setSignal(i[e], e in n);
    }
    if (e.k !== null) {
        // Key-set/$TRACK: objects notify on membership; arrays on any index or
        // length change (mapArray and iteration re-read values — R15).
        const r = Array.isArray(n) && Array.isArray(t) ? arrayStructureChanged(t, n) : membershipChanged(t, n);
        if (r) setSignal(e.k, e => e + 1);
    }
}

// ---------------------------------------------------------------------------
// traps
/** >0 while inside a setter: writes allowed, reads are read-your-writes. */ let writing = 0;

/** Write scope keys (a family object or a plain store's root target): draft
 * semantics — write permission, read-your-writes, tracking suppression —
 * apply ONLY to targets under a scope being written. Reads of OTHER stores
 * inside a setter track normally (they are dependencies: a projection derive
 * reading another store must link it). */ let writeScopes = null;

function scopeKey(e) {
    if (e.fam !== null) return e.fam;
    let t = e;
    while (t.u !== null) t = t.u;
    return t;
}

function inDraft(e) {
    return writeScopes !== null && writeScopes.has(scopeKey(e));
}

/** Shallow serve rule (#2932): raw-marked data serves VERBATIM, but a
 * store-proxy slot value gets a boundary wrapper in THIS store's own family —
 * write isolation through derived chains (downstream writes must never land
 * upstream). markRawOne skips proxies for exactly this reason. */ function serveShallow(e, t, n) {
    if (n !== null && typeof n === "object" && n[$TARGET] !== undefined) return draftServe(e, wrapNext(n, e, t));
    return n;
}

/** Draft reads extend write permission to reachable stores (legacy Writing
 * semantics: wrapping a child through a draft get admits it — cross-store
 * writes like `s.inner.a = 10` work when `inner` is another store's proxy). */ function draftServe(e, t) {
    if (writeScopes !== null && inDraft(e)) {
        const e = t?.[$TARGET];
        if (e !== undefined && e.v !== undefined) writeScopes.add(scopeKey(e));
    }
    return t;
}

/** Targets written during the current (outermost) setter — notified at exit. */ const pendingNotify = new Set;

const UNSAFE_KEYS = new Set([ "__proto__", "prototype", "constructor" ]);

/** Mirror of core read()'s context rule: the OWNER context (not the tracking
 * observer) decides pending visibility, with Roots resolving to their parent
 * computed (#2687 — untracked reads inside mapArray Roots see in-flight
 * values mid-flush). CHILDREN_FORBIDDEN execution scopes (createTrackedEffect
 * / onSettled callbacks) get COMMITTED visibility (#3006), same as core. */ function inOwnerContext() {
    const e = getOwner();
    if (e === null) return false;
    const t = e.Ct ? e.Ot : e;
    return t != null && !(t.T & CONFIG_CHILDREN_FORBIDDEN);
}

/** CHILDREN_FORBIDDEN execution scope (createTrackedEffect / onSettled
 * callbacks). Distinct from context-free: these scopes get committed
 * visibility even against a projection's authoritative-elect pending
 * backing (#3082) — parity with signals, where core read() serves
 * committed to them regardless of staged writes. */ function inForbiddenScope() {
    const e = getOwner();
    if (e === null) return false;
    const t = e.Ct ? e.Ot : e;
    return t != null && !!(t.T & CONFIG_CHILDREN_FORBIDDEN);
}

/** A pending fold is transition-held when any written node's parked value is
 * stamped by a live transition (a plain batch parking — the lazy-recompute
 * read case — has no transition stamp and serves fresh). */ function foldHeld(e) {
    const t = e.n;
    if (t === null) return false;
    for (const e of Reflect.ownKeys(t)) {
        const n = t[e];
        if (n.Pe !== NOT_PENDING && n._e != null && n._e.fn !== true) return true;
    }
    return false;
}

function readSource(e) {
    // Held view first (#3074): an adoption staged under a live hold serves the
    // pre-hold committed backing to committed-visibility readers. Speculative
    // readers — drafts, write-override, owner-context computeds recomputing
    // inside the transaction, and latest() reads — see the adopted backing.
    if (e.ht !== null && !latestReadActive && !inDraft(e) && !getWriteOverride() && !inOwnerContext()) {
        const t = heldMaskView(e);
        if (t !== null) return t;
    }
    // Signal-parity visibility (core read(): owner-context reads serve
    // _pendingValue, context-free reads serve committed — effects recompute
    // BEFORE commitPendingNodes in the flush, so the pending view must be
    // servable). Drafts (setter window OR projection write-override) and
    // owner-context reads see the pending backing; context-free reads see
    // committed. Node reads apply the same rule, so both homes agree.
        if (e.pb !== null && (inDraft(e) || getWriteOverride() || inOwnerContext() || 
    // A projection's pending backing is authoritative-elect: serve it to
    // context-free readers too UNLESS a transition is holding the node
    // commits (downstream async hold — stale committed is the contract)
    // or the reader is a CHILDREN_FORBIDDEN scope, which never observes
    // its own unsettled write (#3082, signal parity per #3006).
    e.fam !== null && !foldHeld(e) && !inForbiddenScope())) return e.pb;
    return e.v;
}

const hasOwn = Object.prototype.hasOwnProperty;

// Allocation-free own-accessor probe (replaces eager descriptor scans — the
// single biggest creation cost in the uibench profile): Annex-B lookups
// return the fn or undefined with no descriptor object. Own data properties
// shadow prototype accessors, so hasOwn + lookup is an exact own-check.
const lookupGetter = Object.prototype.__lookupGetter__;

const lookupSetter = Object.prototype.__lookupSetter__;

function isOwnAccessor(e, t) {
    return hasOwn.call(e, t) && (lookupGetter.call(e, t) !== undefined || lookupSetter.call(e, t) !== undefined);
}

/** Authoritative-write wrapper exported for the optimistic module: sets the
 * scheduler's projectionWriteActive through THIS module's binding (proven to
 * share the instance core reads — cross-module live-binding writes from other
 * store modules were observed not to propagate under the test transform). */ function runAuthoritative(e) {
    const t = projectionWriteActive;
    setProjectionWriteActive(true);
    try {
        return e();
    } finally {
        setProjectionWriteActive(t);
    }
}

/** Active optimistic override on an armed node (armed slot idles at
 * NOT_PENDING; undefined = unarmed plain node). */ function hasActiveOverride(e) {
    return e.o?.De !== undefined && e.o?.De !== NOT_PENDING;
}

/** Context-aware node view for reads outside tracking: active override >
 * held pending (owner context) > the BACKING value. Committed truth lives in
 * the backing (single-home rule, O6) — node `_value` is never served here,
 * so a lazy recompute's landing is immediately visible to the untracked
 * reader that forced it (backing commits eagerly; node values fold at flush).
 * FORCE sentinels never surface (they only bump subscribers of accessor
 * keys, which are served by the trap, not the node). */ function nodeValue(e, t) {
    // latest() sees the in-flight parked value like an owner-context reader
    // does (#3075) — signal/memo parity for store-node-backed keys.
    const n = hasActiveOverride(e) ? unwrapOverride(e.o?.De) : e.Pe !== NOT_PENDING && (latestReadActive || inOwnerContext()) ? e.Pe : t;
    return n === FORCE ? t : n;
}

/** Serve an own data key: node-first when a node exists (pending visibility,
 * holds, lanes ride the node); backing otherwise. Chained backings (§7b: the
 * backing IS another store's proxy) serve the read-through value — the outer
 * node is linked only for adoption-swap notification, its value never
 * shadows the live chain. */ function serveDataKey(e, t, n, r, i) {
    const o = e.ch && r === e.v;
    let f = n;
    // §6: on optimistic arrays LENGTH IS A VIEW, not a node value — one home
    // (backing ± presence overrides) for both length and indices makes torn
    // iteration impossible (a length node's value rides different visibility
    // rails than index overrides mid-settle). The node still carries
    // subscriptions; its value is never served here.
        if (t === "length" && e.fam?.opt === true && !o && Array.isArray(r)) {
        if (!inDraft(e)) {
            const r = e.n?.length;
            if (r !== undefined) {
                if (getObserver() !== null) read(r);
            } else if (getObserver() !== null) {
                read(getNode(e, t, n));
            }
        }
        return optHooks.optimisticView(e, r).length;
    }
    if (inDraft(e)) {
        // Optimistic drafts before their first write have no pending backing yet;
        // reads must still see the live optimistic view (compose, not clobber —
        // #2951). Once ensurePB runs, the seeded clone carries the view.
        if (e.fam?.opt && e.pb === null) {
            const n = e.n?.[t];
            if (n !== undefined && hasActiveOverride(n)) f = unwrapOverride(n.o?.De);
        }
    } else {
        if (i !== undefined) {
            // §7b: a lane value on the outer node SHADOWS read-through — an active
            // override pierces the chained gate; otherwise chained backings always
            // serve the live inner value.
            if (getObserver() !== null) {
                // read()'s plain-signal fast path hoisted over the call (legacy trap
                // parity): READ_SLOW = a global read window or non-plain node.
                let e = readNodeFast(i);
                if (e === READ_SLOW) e = read(i);
                if (!o || hasActiveOverride(i)) f = e === FORCE ? n : e;
            } else if (!o || hasActiveOverride(i)) {
                f = nodeValue(i, n);
            }
        } else if (getObserver() !== null) {
            read(getNode(e, t, n));
        }
    }
    // Shallow stores serve data raw; store-proxy slots get boundary wrappers.
        if (e.s) return serveShallow(e, t, f);
    if (i !== undefined) {
        // Wrap cache (see getNode): only wrappables are ever cached, so a hit
        // skips isWrappable too — pointer-compare replaces both checks.
        if (i.pxv === f && f !== undefined) return draftServe(e, i.px);
        if (!isWrappable(f)) return f;
        const n = wrapNext(f, e, t);
        i.px = n;
        i.pxv = f;
        return draftServe(e, n);
    }
    if (!isWrappable(f)) return f;
    return draftServe(e, wrapNext(f, e, t));
}

/** §6c store-wide status gate for reads that DON'T flow through a node:
 * untracked/raw fallthrough must still throw while the derive is
 * uninitialized (seed invisibility, proj R23) or errored (memo parity).
 * TRACKED reads never call this — store nodes carry `_firewall`, so core
 * read() links the node and throws the firewall's error itself (the node
 * link is what wakes async-memo readers when the landing writes values;
 * the firewall link rides the same read). */ function firewallGate(e) {
    // Own-draft ops are exempt: an async derive's continuation (generator body
    // after an `await`/`yield`) runs OUTSIDE the sync write scope (inDraft is
    // already false), but its draft-proxy traps mark every op with the write
    // override. Those reads are the derive working its own draft (state.push
    // reading .length) — gating them throws NotReadyError back into the derive
    // itself, which the post-await read diagnostic (#2987) then escalates to a
    // reactivity halt. The gate exists for EXTERNAL readers (seed invisibility,
    // proj R23); the derive is the author.
    if (projectionWriteActive || getWriteOverride()) return;
    const t = e.fam?.node;
    if (t != null && t.S & (STATUS_UNINITIALIZED | STATUS_ERROR)) read(t);
}

/** latest() pull (#3075): bring the projection computed up to date so the
 * read serves the IN-FLIGHT derivation — signal/memo parity, where core
 * read() routes latest() through a companion that recomputes speculatively.
 * The latest flag is suspended for the recompute (the derive's own reads
 * are normal reads), and latestPullActive marks any adoption it commits as
 * staged (see adoptPB) — the speculative swap must not leak to
 * committed-visibility readers before the flush. */ function pullProjectionForLatest(e) {
    const t = e.fam.node;
    if (t == null) return;
    const n = latestReadActive;
    setLatestReadActive(false);
    const r = latestPullActive;
    latestPullActive = true;
    try {
        prepareComputed(t, true);
    } finally {
        latestPullActive = r;
        setLatestReadActive(n);
    }
}

const traps = {
    get(e, t, n) {
        // One typeof gates every brand-symbol compare off the hot string path
        // (four symbol comparisons per property read otherwise).
        if (typeof t !== "string") {
            if (t === $TARGET) return e;
            if (t === $PROXY) return n;
            // refresh()/isPending resolve the projection computed through $REFRESH.
                        if (t === $REFRESH) return e.fam?.node ?? undefined;
            if (t === $TRACK) {
                if (pendingCheckActive) witnessAffectsMark(e, t);
                if (e.fam !== null && getObserver() === null && !inDraft(e)) firewallGate(e);
                if (!inDraft(e) && getObserver() !== null) {
                    read(getKeySetNode(e));
                    // Structural chaining (§7b, #2864 / core R21): a chained backing's
                    // $TRACK reads through to the INNER store's key-set — structural
                    // notifications land on the source's own node, never on this
                    // wrapper view's.
                                        const t = readSource(e);
                    if (t[$TARGET] !== undefined) t[$TRACK];
                }
                return undefined;
            }
            // user symbols fall through to the generic path
                }
        if (pendingCheckActive) witnessAffectsMark(e, t);
        if (e.fam !== null && getObserver() === null && !inDraft(e)) firewallGate(e);
        // latest() pull (#3075): store traps never reach core read() without an
        // observer, so bring the projection computed up to date here — signal/
        // memo parity for latest() reads through a projection.
                if (e.fam !== null && latestReadActive && !inDraft(e) && !getWriteOverride()) pullProjectionForLatest(e);
        const r = readSource(e);
        // Overlay delete (#3044): a prototype overlay cannot shadow a delete, so
        // deleted keys are tracked aside and read as absent in the pending view.
                if (e.del !== null && r === e.pb && e.del.has(t)) {
            if (!inDraft(e) && getObserver() !== null) read(getNode(e, t, undefined));
            return undefined;
        }
        // Hot inline case: existing PLAIN node (non-accessor), unchained backing,
        // tracked read of a present data key — the dbmon/uibench effect re-read
        // shape. Skips serveDataKey's frame, the FORCE compare (only accessor
        // keys ever hold the sentinel), and isWrappable for primitives.
                if (e.ch === false && writeScopes === null) {
            const n = e.n?.[t];
            if (n !== undefined && n.acc !== true && getObserver() !== null) {
                let r = readNodeFast(n);
                if (r === READ_SLOW) r = read(n);
                if (r === null || typeof r !== "object") return r;
                if (e.s) return serveShallow(e, t, r);
                if (n.pxv === r) return n.px;
                if (isWrappable(r)) {
                    const i = wrapNext(r, e, t);
                    n.px = i;
                    n.pxv = r;
                    return i;
                }
                return r;
            }
        }
        // Accessor keys serve through Reflect.get with the PROXY receiver
        // (R20/R29: internal reads track; the node is linked for shape-change
        // notification but its value is never served). Accessor-ness comes from
        // the node's cached flag; the first TRACKED read (which creates the
        // node) probes once — untracked node-less reads take the plain path,
        // where a raw-receiver getter still returns correct committed values.
        // Tracking suppression is PER-TARGET (inDraft), never global: `writing`
        // counts every open setter anywhere, and a projection derive runs its
        // whole body inside one — a global gate silently swallowed EXTERNAL
        // absent-key/accessor subscriptions for every store read during any
        // derive, leaving nested projections permanently dependency-less when
        // their sources hadn't materialized yet (#3037).
                const i = e.n?.[t];
        {
            const o = i !== undefined ? i.acc === true : !inDraft(e) && getObserver() !== null && isOwnAccessor(r, t);
            if (o) {
                if (!inDraft(e) && getObserver() !== null) read(i ?? getNode(e, t, undefined));
                const o = Reflect.get(r, t, n);
                if (e.s) return serveShallow(e, t, o);
                return isWrappable(o) ? draftServe(e, wrapNext(o, e, t)) : o;
            }
        }
        // Plain-data fast path: no descriptor allocation per read.
        // Inherited pollution keys are never served (core R30) — checked before
        // the proto-function branch can leak `constructor`. Interned-string
        // compares beat a Set hash on this per-read path. Overlay pending
        // backings chain to the committed backing, so "own in the view" means
        // own on either layer (ownInView) — a genuine prototype method is one
        // that is own on NEITHER.
                const o = e.ovl && r === e.pb;
        if ((t === "constructor" || t === "__proto__" || t === "prototype") && !hasOwn.call(r, t) && !(o && hasOwn.call(e.v, t))) return undefined;
        let f = r[t];
        if (f === undefined ? !hasOwn.call(r, t) && !(o && hasOwn.call(e.v, t)) : false) {
            // Inherited: prototype getters/methods run with the proxy receiver.
            f = Reflect.get(r, t, n);
            if (typeof f === "function") return f;
 // proto methods untracked
            // Reading a currently-absent own key subscribes to it (R12) — for any
            // target OUTSIDE its own draft scope, even mid-setter (#3037, above).
                        if (f === undefined && !inDraft(e)) {
                if (getObserver() !== null) read(getNode(e, t, undefined));
                const n = e.n?.[t];
                if (n) {
                    const r = nodeValue(n, undefined);
                    if (e.s) return serveShallow(e, t, r);
                    return isWrappable(r) ? draftServe(e, wrapNext(r, e, t)) : r;
                }
            } else if (f === undefined && inDraft(e) && e.fam?.opt && e.pb === null) {
                const n = e.n?.[t];
                if (n !== undefined && hasActiveOverride(n)) f = unwrapOverride(n.o?.De);
            }
            if (e.s) return serveShallow(e, t, f);
            return isWrappable(f) ? draftServe(e, wrapNext(f, e, t)) : f;
        }
        if (typeof f === "function" && !hasOwn.call(r, t) && !(o && hasOwn.call(e.v, t))) return f;
 // proto method
                return serveDataKey(e, t, f, r, i);
    },
    has(e, t) {
        if (t === $TARGET || t === $PROXY || t === $TRACK) return true;
        if (pendingCheckActive) witnessAffectsMark(e, t);
        if (e.fam !== null && getObserver() === null && !inDraft(e)) firewallGate(e);
        const n = readSource(e);
        let r = t in n;
        // Overlay deletes read as absent in the pending view (#3044).
                if (r && e.del !== null && n === e.pb && e.del.has(t)) r = false;
        if (!inDraft(e)) {
            if (getObserver() !== null) {
                const n = getHasNode(e, t, r);
                const i = read(n);
                if (hasActiveOverride(n)) r = !!i;
            } else {
                const n = e.h?.[t];
                if (n !== undefined && hasActiveOverride(n)) r = !!unwrapOverride(n.o?.De);
            }
        } else if (e.fam?.opt && e.pb === null) {
            const n = e.h?.[t];
            if (n !== undefined && hasActiveOverride(n)) r = !!unwrapOverride(n.o?.De);
        }
        return r;
    },
    ownKeys(e) {
        if (pendingCheckActive) witnessAffectsMark(e);
        if (e.fam !== null && getObserver() === null && !inDraft(e)) firewallGate(e);
        if (!inDraft(e) && getObserver() !== null) read(getKeySetNode(e));
        const t = readSource(e);
        let n;
        if (e.ovl && t === e.pb) {
            // Overlay merge (#3044): committed keys in their order, then this
            // batch's NEW keys, minus deletes.
            n = Reflect.ownKeys(e.v);
            const r = e.del;
            if (r !== null && r.size !== 0) n = n.filter(e => !r.has(e));
            for (const r of Reflect.ownKeys(t)) {
                if (!hasOwn.call(e.v, r)) n.push(r);
            }
        } else n = Reflect.ownKeys(t);
        // Optimistic membership overlay: presence-node overrides add/remove keys
        // (per-transaction lifecycle rides the nodes — §6, FINDING-2's fix).
        // Draft reads before the first write overlay too (pb, once created, is
        // seeded with the view).
                if (e.fam?.opt && e.h !== null && (!inDraft(e) || e.pb === null)) {
            let t = null;
            for (const r of Reflect.ownKeys(e.h)) {
                const i = e.h[r];
                if (!hasActiveOverride(i)) continue;
                t ??= new Set(n);
                if (unwrapOverride(i.o?.De)) t.add(r); else t.delete(r);
            }
            if (t !== null) return [ ...t ];
        }
        return n;
    },
    getOwnPropertyDescriptor(e, t) {
        const n = readSource(e);
        let r = Object.getOwnPropertyDescriptor(n, t);
        // Overlay (#3044): unwritten keys live on the committed backing;
        // deleted keys are absent from the pending view.
                if (e.ovl && n === e.pb) {
            if (e.del !== null && e.del.has(t)) return undefined;
            if (r === undefined) r = Object.getOwnPropertyDescriptor(e.v, t);
        }
        if (e.fam?.opt && !inDraft(e)) {
            const n = e.h?.[t];
            if (n !== undefined && hasActiveOverride(n)) {
                if (!unwrapOverride(n.o?.De)) return undefined;
 // opt delete
                                if (r === undefined) {
                    const n = e.n?.[t];
                    return {
                        value: n !== undefined ? nodeValue(n, undefined) : undefined,
                        writable: true,
                        enumerable: true,
                        configurable: true
                    };
                }
            }
        }
        if (r === undefined) return undefined;
        // Array targets carry a real non-configurable `length` the proxy
        // invariant forces us to report faithfully; everything else reports
        // configurable via target indirection (core R51).
                if (!(t === "length" && Array.isArray(e))) r.configurable = true;
        return r;
    },
    set(e, t, n) {
        // Writes require the target's draft scope OR the projection write
        // override (post-await async draft writes arrive outside any window);
        // everything else is silently ignored (R23).
        const r = inDraft(e);
        const i = !r && getWriteOverride();
        if (!r && !i) return true;
        if (t === "__proto__") return true;
 // pollution guard (core R30)
        // Unwrap BEFORE ensurePB: unwrapValue materializes a self-referencing
        // draft's overlay (replacing target.pb), so a pb local captured earlier
        // would be the abandoned overlay and the write would vanish.
        // Shallow slots store what was written VERBATIM — another store's proxy
        // passes through by reference (#2932; markRawOne skips proxies), while
        // deep stores unwrap to raw backings.
                const o = e.s ? n : unwrapValue(n);
        const f = ensurePB(e);
        pendingNotify.add(e);
        // Array length writes implicitly delete indices — the written-keys bound
        // can't see them, so poison to the full scan for this batch. Index
        // writes implicitly GROW length, so arrays always record it alongside.
                const l = pcOf(e);
        if (Array.isArray(f)) {
            if (t === "length") l.wk = WK_ALL; else if (l.wk !== WK_ALL) {
                const e = l.wk ??= new Set;
                e.add(t);
                e.add("length");
            }
        } else if (l.wk !== WK_ALL) (l.wk ??= new Set).add(t);
        // Own data keys literally named "prototype"/"constructor" land as data —
        // defineProperty sidesteps a proto-chain setter named the same.
                if (UNSAFE_KEYS.has(t)) {
            Object.defineProperty(f, t, {
                value: o,
                writable: true,
                enumerable: true,
                configurable: true
            });
            if (e.del !== null) e.del.delete(t);
            return true;
        }
        // Overlay first-write DEFINES the own key: assignment through the proto
        // chain would reject on a non-writable committed property (the clone
        // path normalized descriptors for exactly this — R51 parity).
                if (e.ovl && !hasOwn.call(f, t)) {
            Object.defineProperty(f, t, {
                value: o,
                writable: true,
                enumerable: true,
                configurable: true
            });
        } else f[t] = o;
        if (e.del !== null) e.del.delete(t);
        // Shallow ingest: written records are sticky raw-marked (one entity is
        // never both deep-wrapped and raw — R41/#2932, shared invariant).
                if (e.s && o !== null && typeof o === "object") markRawOne(o);
        // Override-mode (post-await draft) writes have no setter exit — notify
        // per-op (setSignal equality-gates repeats).
                if (i) notifyWrites(e);
        return true;
    },
    defineProperty(e, t, n) {
        const r = inDraft(e);
        const i = !r && getWriteOverride();
        if (!r && !i) return true;
        if (t === "__proto__") return true;
        if (n.get || n.set) {
            e.a = true;
            // Accessor demotion (re-audit blocker 3): a record that acquires an
            // accessor after patch registration stops being patchable — pull its
            // patches and re-drive them as tracked effect fallbacks. Hooks are
            // installed whenever pc.p exists (registration installs them).
                        if (e.pc !== null && e.pc.p !== null) patchHooks.demoteToEffects(e);
        }
        // Unwrap before ensurePB (see the set trap: self-reference materializes).
                if ("value" in n) n = {
            ...n,
            value: unwrapValue(n.value)
        };
        const o = ensurePB(e);
        pendingNotify.add(e);
        const f = pcOf(e);
        if (f.wk !== WK_ALL) (f.wk ??= new Set).add(t);
        Object.defineProperty(o, t, n);
        if (e.del !== null) e.del.delete(t);
        if (i) notifyWrites(e);
        return true;
    },
    deleteProperty(e, t) {
        const n = inDraft(e);
        const r = !n && getWriteOverride();
        if (!n && !r) return true;
        const i = ensurePB(e);
        pendingNotify.add(e);
        const o = pcOf(e);
        if (o.wk !== WK_ALL) (o.wk ??= new Set).add(t);
        delete i[t];
        // A prototype overlay cannot shadow a delete of a committed key —
        // record it aside (#3044); reads/has/ownKeys/commit consult the set.
                if (e.ovl && hasOwn.call(e.v, t)) (e.del ??= new Set).add(t);
        if (r) notifyWrites(e);
        return true;
    }
};

/** Low-level setter primitive: opens write mode on a next proxy, runs `fn`,
 * emits write-time notifications at outermost exit, applies returned
 * replacements as adoptions. `guard=false` skips the owned-scope dev guard —
 * projection recomputes legitimately write from inside their computed. */ function storeSetterNext(e, t, n = true) {
    const r = e[$TARGET];
    const i = writeScopes;
    writeScopes = new Set;
    writeScopes.add(scopeKey(r));
    writing++;
    let o;
    try {
        // No untrack: the writing flag already disables store-node linking
        // (draft reads never self-track, proj R2), while EXTERNAL reads (signals
        // inside a projection derive) must keep tracking — they are the derive's
        // dependencies.
        o = t(e);
    } finally {
        writing--;
        writeScopes = i;
        // Outermost setter exit: emit write-time notifications (setSignal per
        // changed observed key) so transition holds and lanes engage now.
                if (writing === 0 && pendingNotify.size) {
            const e = [ ...pendingNotify ];
            pendingNotify.clear();
            for (const t of e) notifyWrites(t);
        }
    }
    if (o !== undefined && o !== e && isWrappable(o)) {
        // Returned replacement: on an optimistic family (outside authoritative
        // writes) the replacement is itself an optimistic edit — diff it against
        // the visible view as engine writes (reverts at settle). Otherwise it is
        // an adoption of the incoming object (unowned).
        if (r.fam?.opt && !projectionWriteActive && !getWriteOverride()) {
            optHooks.notifyOptimisticWrites(r, unwrapValue(o));
        } else {
            adoptPB(r, unwrapValue(o));
        }
    }
}

// Affects integration: the legacy affects machinery reads next targets
// structurally (aliased field names); only node CREATION dispatches here.
setNextAffectsNodeResolver((e, t) => t === $AFFECTS ? getNode(e, $AFFECTS, undefined) : getNode(e, t, (e.pb ?? e.v)[t]));

function createStoreNext(e, t = false) {
    const n = wrapNext(e);
    if (t) {
        n[$TARGET].s = true;
        markRawIngest(e);
    }
    const setter = e => storeSetterNext(n, e);
    return [ n, setter ];
}

/** True when `proxy` is a SHALLOW store (children served verbatim, slots
 * replaced by reference — #2932). The list driver uses this to choose the
 * slot-patch channel (collected row bodies) over per-record registration. */ function storeIsShallow(e) {
    const t = e?.[$TARGET];
    return t !== undefined && t.s === true;
}

/** True when `proxy` belongs to a projection/optimistic FAMILY. The list
 * driver must DECLINE family arrays (external audit finding): family
 * structural changes never emit row/slot ops (the setter channel is
 * fam-gated; optimistic writes ride node overrides), and the proxy identity
 * is stable so the each-watch cannot catch the change either — an engaged
 * list would freeze on optimistic/projection structural updates. Record-
 * level family patches are unaffected (they have their own emission). */ function storeHasFamily(e) {
    const t = e?.[$TARGET];
    return t !== undefined && t.fam !== null;
}

/** True when `proxy` belongs to an OPTIMISTIC family specifically. The list
 * driver declines these (audit finding, narrowed): optimistic user writes
 * ride node-level overrides — they never enter the reconcile walk, so no
 * row/slot ops are emitted and an engaged list would freeze on optimistic
 * structural changes. PROJECTION (non-optimistic) families are drivable:
 * their recomputes go through the reconcile walk, whose emissions are
 * transition-stamped in the apply queue like any other (equivalence-matrix
 * gated). Re-admitting optimistic families requires a lane-timed structural
 * emission mirroring emitPatchOptimistic, plus revert resync. */ function storeHasOptimisticFamily(e) {
    const t = e?.[$TARGET];
    return t !== undefined && t.fam?.opt === true;
}

/** Tracking deep snapshot (`deep()` for next targets): subscribes to the
 * key-set and deep-witness node at every reachable level, then returns the
 * plain view. Shared references and cycles handled via the visited set. */ function deepNext(e) {
    const t = e?.[$TARGET];
    if (t === undefined || t.px !== e) return e;
    const n = new Set;
    // One membership node + one deep-witness node PER RECORD (legacy $TRACK
    // parity): the walk stays O(records) in subscriptions instead of O(paths)
    // in per-key nodes, and it walks TARGETS directly — no per-child proxy
    // round-trip (wrapNext → proxy → $TARGET trap) on the re-walk every
    // effect run performs.
        const walkT = e => {
        const t = readSource(e);
        if (n.has(t)) return;
        n.add(t);
        read(getKeySetNode(e));
        read(getDeepNode(e));
        const r = e.fam?.map ?? storeNextLookup;
        for (const n of Reflect.ownKeys(t)) {
            const i = Object.getOwnPropertyDescriptor(t, n);
            if (i === undefined) continue;
            if (i.get || i.set) {
                e.a = true;
                continue;
 // accessors track through their own reads when invoked
                        }
            const o = i.value;
            if (o === null || typeof o !== "object") continue;
            // Stored proxies (chained slots) resolve through their own target;
            // raw children through the family map, created on first visit.
                        let f = o[$TARGET] ?? r.get(o);
            if (f === undefined) {
                if (!isWrappable(o)) continue;
                wrapNext(o, e, n);
                f = r.get(o);
                if (f === undefined) continue;
 // raw-marked: leaf by contract
                        }
            walkT(f);
        }
    };
    walkT(t);
    return snapshotNext(e);
}

/**
 * Snapshot with per-object registration resolution (RUL-12 DAG ruling): every
 * reachable wrappable resolves through its target's CURRENT backing, so
 * privatized subtrees are seen through any parent path. Identity-preserving:
 * a subtree with no substitutions below returns its own object (zero copy for
 * settled, never-diverged graphs).
 */ function snapshotNext(e) {
    const t = e?.[$TARGET];
    return snapshotWalk(e, new Map, t?.fam ?? null);
}

function snapshotWalk(e, t, n) {
    if (e === null || typeof e !== "object") return e;
    // Resolve through the registration: proxies AND raws map to their target's
    // current backing (stale raw pointers through other parents resolve here).
    // Loops for chained backings (§7b: a projection's backing can be another
    // store's proxy — snapshot unwraps to the base raw).
        let r = e;
    // Chained backings can pass through several targets; optimistic overrides
    // on OUTER targets shadow the chain (§7b), so collect every opt target
    // encountered and compose their views over the resolved base, innermost
    // outward.
        let i = null;
    for (;;) {
        let e = r?.[$TARGET]?.v !== undefined ? r[$TARGET] : undefined;
        if (e === undefined && n !== null) e = n.map.get(r);
        if (e === undefined) e = storeNextLookup.get(r);
        if (e === undefined) break;
        if (e.fam !== null) n = e.fam;
        if (e.fam?.opt === true) (i ??= []).push(e);
        // Snapshot runs mid-flush (tracked memos execute before commit), so a
        // pending prototype overlay must present as a REAL merged container.
                if (e.ovl) materializePB(e);
        const t = e.pb ?? e.v;
        if (t === r) break;
        r = t;
    }
    if (!isWrappable(r)) return r;
    // Optimistic families: compose the visible view; a composed view is a fresh
    // object and snapshots via the owned/copy path (pinned `not.toBe` identity).
        if (i !== null) {
        let e = r;
        for (let t = i.length - 1; t >= 0; t--) e = optHooks.optimisticView(i[t], e);
        if (e !== r) {
            const i = t.get(r);
            if (i !== undefined) return i;
            const o = Array.isArray(e);
            const f = o ? [] : Object.create(Object.getPrototypeOf(e));
            t.set(r, f);
            for (const r of Reflect.ownKeys(e)) {
                if (o && r === "length") continue;
                const i = e[r];
                f[r] = i !== null && typeof i === "object" ? snapshotWalk(i, t, n) : i;
            }
            if (o) f.length = e.length;
            return f;
        }
    }
    const o = t.get(r);
    if (o !== undefined) return o;
    // OWNED (written) subtrees snapshot as copies (§7b: identity is only for
    // subtrees "unmodified relative to source"): non-enumerable symbols are
    // excluded (recon-snap R29), and the copy registers BEFORE descent so
    // cycles keep identity (FINDING-3).
        if (ownedRaw.has(r)) {
        const e = Array.isArray(r);
        const i = e ? [] : Object.create(Object.getPrototypeOf(r));
        t.set(r, i);
        for (const o of Reflect.ownKeys(r)) {
            if (e && o === "length") continue;
            const f = Object.getOwnPropertyDescriptor(r, o);
            if (typeof o === "symbol" && !f.enumerable) continue;
            if (f.get || f.set) {
                Object.defineProperty(i, o, f);
                continue;
            }
            const l = f.value;
            const u = l !== null && typeof l === "object" ? snapshotWalk(l, t, n) : l;
            if (f.enumerable && f.writable && f.configurable) i[o] = u; else Object.defineProperty(i, o, {
                ...f,
                value: u
            });
        }
        if (e && i.length !== r.length) i.length = r.length;
        return i;
    }
    // UNOWNED (shared/user) subtrees keep identity unless a descendant
    // substituted; copy-on-substitution preserves the documented CoW contract.
        t.set(r, r);
    let f = null;
    for (const e of Reflect.ownKeys(r)) {
        const i = Object.getOwnPropertyDescriptor(r, e);
        if (!i || i.get || i.set) continue;
        const o = i.value;
        if (o === null || typeof o !== "object") continue;
        const l = snapshotWalk(o, t, n);
        if (l !== o) {
            if (f === null) {
                f = Array.isArray(r) ? [ ...r ] : Object.create(Object.getPrototypeOf(r), Object.getOwnPropertyDescriptors(r));
                t.set(r, f);
            }
            f[e] = l;
        }
    }
    return f ?? r;
}

export { adoptPB, bumpDeep, createStoreNext, deepNext, getHasNode, getKeySetNode, getNode, hasAccessorFlag, hasActiveOverride, materializePB, notifyFold, notifyFoldTail, notifyKeyDiff, notifyKeyValue, pcOf, runAuthoritative, snapshotNext, storeHasFamily, storeHasOptimisticFamily, storeIsShallow, storeSetterNext, targetIsPlain, targetsEqual, unwrapValue, wrapNext };