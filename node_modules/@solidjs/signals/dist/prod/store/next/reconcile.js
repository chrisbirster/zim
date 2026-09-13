import { isEqual } from "../../core/core.js";

import { projectionWriteActive } from "../../core/scheduler.js";

import "../../core/invariants.js";

import "../../core/verdict.js";

import "../../core/effect.js";

import { patchHooks, rowHooks } from "./patch-hooks.js";

import { $TARGET, markRawIngest, isWrappable, rawValuesUsed, isRawValue, getWriteOverride } from "../store.js";

import { materializePB, adoptPB, unwrapValue, notifyFold, targetsEqual, bumpDeep, notifyKeyValue, notifyKeyDiff, notifyFoldTail, hasAccessorFlag } from "./store.js";

import { storeNextLookup, optHooks, ownedRaw } from "./target.js";

/**
 * Store rewrite — reconcile, the adoption channel (INTERNALS-STORE-STATE.md
 * §3, decision 2026-08-16c). Reconcile never merge-writes: it adopts `next`
 * as the authoritative pending backing at every proxied level (pointer swap
 * folded at flush commit), notification riding the fold's descriptor diff.
 *
 * Structural optimizations (all kept, per 2026-08-17 morning ruling):
 * - Identity skip with completed proof: `incoming === backing && !owned` —
 *   sound because input is immutable by convention (R2a) and ownership marks
 *   the only writer the convention doesn't cover (us). Fixes FINDING-1.
 * - Reachability pruning: descent happens only where a child TARGET exists
 *   (proxies exist only where read) — never-subscribed subtrees are never
 *   walked (recon-snap R17), while a subscriber deep below an untracked path
 *   keeps its chain walkable because wrapping created the intermediate
 *   targets (recon-snap R16).
 * - Keyed matching ported semantics: key-matched rows keep proxy identity;
 *   key mismatch detaches (fresh proxy on next read, recon-snap R18);
 *   keyless items fall back positional; null/primitive slots are legal
 *   members (R11). Kind changes replace wholesale (R10).
 */ function reconcileNextState(e, n, t, o = false) {
    if (n == null) throw new Error("");
    const l = n?.[$TARGET];
    if (l === undefined || l.px !== n) throw new Error("");
    // Reconcile's diff walks need a REAL pending container — a prototype
    // overlay (#3044) materializes to the clone path first (edge: reconcile
    // inside a setter that already wrote this target).
        if (l.ovl) materializePB(l);
    let i = t === null ? null : typeof t === "string" ? e => e?.[t] : t;
    // §7b chained backing: a projection derive returning a LIVE store proxy
    // adopts the proxy itself as the backing — reads flow through the inner
    // store's traps, so consumers subscribe to the inner graph and updates
    // flow with no re-derive (#2941). The adoption diff still notifies THIS
    // store's existing subscribers of the swap.
        if (o && e !== n && e?.[$TARGET] !== undefined) {
        const n = l.pb ?? l.v;
        if (n === e) return;
 // already chained to this store
                adoptPB(l, e);
        return;
    }
    const u = unwrapValue(e);
    if (i) {
        // Root identity precondition — checked before ANY mutation, so a throwing
        // reconcile is atomic by construction (RUL-12 ruling). Projections
        // (replace=true) relax it: a root entity change merges in place — the
        // root proxy is stable for life (proj R5/R11) — and children are NOT
        // key-matched across the entity change (proj R7: keyFn drops to
        // positional so old-entity subtrees never merge into the new entity's).
        const e = l.pb ?? l.v;
        const n = i(e);
        if (n !== undefined && !sameKey(i(u), n)) {
            if (!o) throw new Error("");
            // Entity change: wholesale swap. The root proxy is stable for life
            // (proj R5) but NOTHING below survives — children are never matched
            // across an entity change even when their own keys align (proj R7).
            // Displaced-raw unregistration (proj R10): the outgoing raw stops
            // resolving to this proxy; re-handed later it wraps fresh.
                        (l.fam?.map ?? storeNextLookup).delete(l.pb ?? l.v);
            adoptPB(l, u);
            return;
        }
    }
    // Tentative channel (§6b, RUL-5): a user-context reconcile on an optimistic
    // family parks as engine overrides — values, membership, and length ride
    // armed nodes (reverting with their transaction); committed raw is never
    // touched. Key-matched rows keep proxy identity by descending into the
    // existing child targets instead of overriding their parent slots.
        if (l.fam?.opt === true && !projectionWriteActive && !getWriteOverride()) {
        optHooks.applyTentative(l, u, i);
        return;
    }
    applyAdopt(l, u, i, o);
}

function applyAdopt(e, n, t, o = false) {
    const l = e.pb ?? e.v;
    // The sound identity skip (O7): same reference AND we never diverged it.
        if (n === l && !ownedRaw.has(l)) return;
    const i = e.fam;
    // §6b (R28): the diff's previous-arrangement baseline is the LANE VIEW —
    // optimistic rows must be visible to key matching so a landing carrying the
    // same key recycles their proxies. Raw `prev` keeps the identity/ownership
    // roles above; only matching reads the view.
        const u = i?.opt === true ? optHooks.optimisticView(e, l) : l;
    const f = Array.isArray(n);
    // Plain stores notify inline AFTER the descent (child registrations feed
    // the fold diff's identity-preservation check); projections keep deferred
    // folds (downstream holds can form later in the flush).
        const s = i === null;
    const r = e.s === true;
    const c = e.v;
    adoptPB(e, n, s);
    // Patch channel (adoption site): this record transitioned — queue its
    // patches with the pre-adopt prev. No bubbling walk: the adoption walk
    // visits parents before children, so ancestors emitted already. EAGER
    // only — family targets' visibility moment is their fold commit
    // (drainFolds emits there; emitting here too would double-fire).
        if (patchHooks !== null && s && e.pc !== null && e.pc.p !== null) {
        // Accessor demotion at the ADOPTION seam is DEV-ONLY (prod principle:
        // explicitly-odd input must not cost correct-input prod — the
        // per-adoption scan was ~12% of dbmon's tick since adoptPB resets the
        // verdict every adoption). Dev demotes AND warns; prod emits directly,
        // so a getter adoptee's OUTSIDE deps (signals) won't re-apply in prod —
        // caught loudly during development instead. Registration-time admission
        // (patchableRaw) keeps its full one-time scan in both modes.
        {
            patchHooks.emitPatchLocal(e, n, c);
        }
    }
    // Shallow adoption: records are slot values — sticky raw-mark the incoming
    // set (R41) and never descend; slot notification is the positional diff.
        if (r) markRawIngest(n);
    if (Array.isArray(u) !== f) {
        if (s) notifyFold(e, c, n);
        return;
    }
    if (f) {
        const l = u;
        const f = n;
        // Fused array walk (eager mode): per-index notification rides the same
        // loop as the descent (descend first — targetsEqual needs the child's
        // re-registration, R9). Length, trailing removed indexes, and any other
        // unvisited node keys land in the counted sweep below.
                const a = s ? e.n : null;
        let p = 0;
        if (t && !r) {
            // Positional-prefix fast path (legacy keyedMatch-walk parity): while
            // rows key-match in place — the steady-state polling shape — descend
            // directly with zero staging. The prevByKey map is built only for the
            // misaligned remainder, and never at all on aligned ticks.
            const u = l.length;
            const s = f.length;
            let r = false;
            let d = 0;
            for (const y = Math.min(u, s); d < y; d++) {
                const u = f[d];
                const s = l[d];
                // Routing heuristic only (aligned vs keyed remainder) — both routes
                // notify identically and descend() is the one authoritative
                // validator, so bare typeof gates suffice here; full isWrappable
                // per row was the walk's dominant residual cost.
                                if (s !== u && !(s !== null && typeof s === "object" && u !== null && typeof u === "object" && sameKey(t(s), t(u)))) break;
 // misaligned: fall to the keyed remainder below
                // Identity skip inline (FINDING-1 guard), then descend the pair.
                                if ((s !== u || u !== null && typeof u === "object" && ownedRaw.has(u)) && u !== null && typeof u === "object") descend(unwrapValue(s), u, t, i, o);
                if (e.dk !== null && !r && !(u !== null && typeof u === "object" ? targetsEqual(s, u) : isEqual(s, u))) {
                    bumpDeep(e);
                    r = true;
                }
                if (a !== null) {
                    const e = a[d];
                    if (e !== undefined) {
                        p++;
                        notifyKeyValue(e, d, c[d], u, c, n);
                    }
                }
            }
            if (e.dk !== null && !r && d < f.length) bumpDeep(e);
            const y = d;
 // misalignment point (== nlen on aligned ticks)
                        let w = null;
            for (;d < f.length; d++) {
                const e = f[d];
                // typeof gates route; descend validates (same contract as the prefix).
                                if (e !== null && typeof e === "object") {
                    const n = t(e);
                    let u;
                    if (n !== undefined) {
                        if (w === null) {
                            // Occurrence-aware (re-audit 2, P1-5): duplicate keys queue
                            // their prev INDICES (rows can themselves be arrays, so index
                            // queues are the unambiguous encoding — same as buildRowOps)
                            // and each is consumed ONCE. First-wins would adopt two next
                            // rows into the SAME prev target while row ops retain two
                            // separate DOM rows (the second one stale).
                            w = new Map;
                            // From structStart, not 0 (re-audit 3, P1-2): prefix-aligned
                            // rows already adopted their incoming counterparts — re-offering
                            // them here let a duplicate key adopt a prefix row AGAIN while
                            // row ops (which correctly window from structStart) retained
                            // the later occurrence's DOM row against a never-adopted target.
                                                        for (let e = y; e < l.length; e++) {
                                const n = unwrapValue(l[e]);
                                if (n !== null && typeof n === "object") {
                                    const o = t(n);
                                    if (o === undefined) continue;
                                    const l = w.get(o);
                                    if (l === undefined) w.set(o, e); else if (Array.isArray(l)) l.push(e); else w.set(o, [ l, e ]);
                                }
                            }
                        }
                        const e = w.get(n);
                        if (e === undefined) u = undefined; else if (Array.isArray(e)) {
                            u = unwrapValue(l[e.shift()]);
                            if (e.length === 1) w.set(n, e[0]);
                        } else {
                            u = unwrapValue(l[e]);
                            w.delete(n);
                        }
                    } else {
                        u = unwrapValue(l[d]);
 // keyless item: positional fallback
                                        }
                    descend(u, e, t, i, o);
                }
                if (a !== null) {
                    const e = a[d];
                    if (e !== undefined) {
                        p++;
                        notifyKeyDiff(e, d, c, n, false);
                    }
                }
            }
            // Row ops (PR-B): emit structural ops ONLY when structure changed —
            // aligned value ticks pay nothing. Built after the walk so retained
            // rows' value patches queue first (adds bind at op-apply).
                        if (rowHooks !== null && e.pc !== null && e.pc.ro !== null && (y < s || u !== s)) buildAndEmitRowOps(e, l, f, y, t);
        } else {
            const u = Math.min(l.length, f.length);
            const s = f.length;
            let d = false;
            const y = rowHooks !== null && e.pc !== null ? e.pc.sp : null;
            // Row ops for shallow/positional lists: track the key-aligned prefix
            // (keyed) so aligned value ticks emit nothing; keyless lists emit only
            // on length change (append/truncate). Slot-patch consumers need the
            // alignment tracking too (aligned = value tick, misaligned = ops).
                        const w = rowHooks !== null && e.pc !== null ? e.pc.ro : null;
            let b = t !== null && (w !== null || y !== null);
            let m = 0;
            for (let w = 0; w < s; w++) {
                const s = f[w];
                if (b && w < u) {
                    const e = l[w];
                    if (e !== null && typeof e === "object" && s !== null && typeof s === "object" && 
                    // SameValueZero (self-sweep): strict === here broke slot
                    // alignment on NaN keys while buildRowOps retained the row —
                    // retained DOM with suppressed value ticks (the round-1 NaN
                    // staleness, in the shallow branch).
                    sameKey(t(e), t(s))) m++; else b = false;
                }
                // Slot-patch dispatch (shallow): a KEY-ALIGNED slot whose value was
                // replaced by reference is a value tick — emit through the queue.
                // Misaligned/appended slots are STRUCTURE (row ops rebuild or move
                // them; new rows initial-apply at bind), so they emit nothing here.
                // Keyless positional lists treat same-index replacement as the value
                // tick for indices below the common length.
                // `i < dlen` is load-bearing for BOTH modes: an appended position
                // past a fully-aligned prefix (vacuously aligned when prev is empty)
                // has no previous slot — emitting a slot tick for it races the row
                // ops that CREATE the row (the slot queue applies first, indexing a
                // row that does not exist yet). Equivalence-matrix finding:
                // clear-then-refill and pure appends crashed the driver.
                                if (y !== null && w < u && (t === null || b)) {
                    const n = l[w];
                    if (n !== s) rowHooks.emitSlotPatch(e, w, s, n);
                }
                if (!r && w < u && s !== null && typeof s === "object") descend(unwrapValue(l[w]), s, t, i, o);
                if (e.dk !== null && !d && !(s !== null && typeof s === "object" ? targetsEqual(l[w], s) : isEqual(l[w], s))) {
                    bumpDeep(e);
                    d = true;
                }
                if (a !== null) {
                    const e = a[w];
                    if (e !== undefined) {
                        p++;
                        notifyKeyDiff(e, w, c, n, false);
                    }
                }
            }
            if (w !== null) {
                const n = l.length;
                if (t !== null) {
                    if (m < s || n !== s) buildAndEmitRowOps(e, l, f, m, t);
                } else if (n !== s) {
                    buildAndEmitRowOps(e, l, f, u, null);
                }
            }
        }
        if (s) {
            if (a !== null && p < e.nc) {
                for (const e of Reflect.ownKeys(a)) {
                    // visited indexes are < nextRows.length; everything else sweeps
                    const t = typeof e === "string" ? +e : NaN;
                    if (!(t >= 0 && t < f.length)) notifyKeyDiff(a[e], e, c, n, false);
                }
            }
            notifyFoldTail(e, c, n);
        }
        return;
    } else {
        // FUSED adoption walk (eager mode): one pass fetches each key's pair,
        // descends, then notifies its node inline — descend runs FIRST so the
        // child's re-registration is visible to targetsEqual (identity-preserved
        // slots must not notify, R9). This replaces the notifyFold re-walk that
        // doubled dbmon's diff cost. for-in covers own enumerable string keys
        // with no key-array allocation; symbols get a pass only when present.
        // PROTOTYPE compiled-patch fast path: a pure-patch record (no nodes,
        // no presence/key-set/deep subscribers, no family) adopts and hands the
        // (next, prev) pair to its compiled patch — no per-key walk at all.
        if (e.pc !== null && e.pc.p !== null && s && e.n === null && e.h === null && e.k === null && e.dk === null && i === null) {
            // Adoption already ran at applyAdopt entry; emission was queued there.
            return;
        }
        const l = s ? e.n : null;
        let f = 0;
        let a = false;
        // The per-key body is inlined on purpose (legacy applyStateFast parity:
        // an extracted helper costs a call per key on the hottest object-diff
        // site). Reference-identical values early-continue BEFORE any other
        // work — sound only with the ownership guard (FINDING-1: an owned
        // backing is setter-diverged and must still diff).
                for (const s in n) {
            const p = n[s];
            const d = c[s];
            const y = p !== null && typeof p === "object";
            if (d === p && (!y || !ownedRaw.has(p)) && (l === null || l[s] === undefined || !hasAccessorFlag(l[s]))) {
                if (l !== null && l[s] !== undefined) f++;
                continue;
            }
            if (y && !r) descend(unwrapValue(u[s]), p, t, i, o);
            // Deep-witness (dk): value changes must notify even with NO per-key
            // node — deep() subscribes one node per record. Checked after descend
            // so in-place adoptions (same logical slot) don't bump; child records
            // carry their own witness. One flag + null check when unused.
                        if (e.dk !== null && !a && !(y ? targetsEqual(d, p) : isEqual(d, p))) {
                bumpDeep(e);
                a = true;
            }
            if (l !== null) {
                const e = l[s];
                if (e !== undefined) {
                    f++;
                    notifyKeyValue(e, s, d, p, c, n);
                }
            }
        }
        const p = Object.getOwnPropertySymbols(n);
        for (let e = 0; e < p.length; e++) {
            const s = p[e];
            const a = n[s];
            if (!r && a !== null && typeof a === "object") descend(unwrapValue(u[s]), a, t, i, o);
            if (l !== null) {
                const e = l[s];
                if (e !== undefined) {
                    f++;
                    notifyKeyValue(e, s, c[s], a, c, n);
                }
            }
        }
        if (s) {
            // Deleted-key nodes (in the map but absent from incoming) — counted
            // fast-out: when every node was visited, skip the sweep entirely.
            if (l !== null && f < e.nc) {
                for (const e of Reflect.ownKeys(l)) {
                    if (!hasOwnP.call(n, e)) notifyKeyDiff(l[e], e, c, n, false);
                }
            }
            notifyFoldTail(e, c, n);
        }
        return;
    }
}

const hasOwnP = Object.prototype.hasOwnProperty;

/** Setter-channel row ops (the fold site calls this for array targets with
 * ops consumers): structural mutation through the setter — push/splice/index
 * assignment/permutation — is a visibility transition for the list container
 * just like a reconcile walk, and drivers consuming registerRowOps must see
 * it. Setter mutations move the SAME row objects around, so RAW IDENTITY is
 * the key. Aligned arrays (value-only folds) emit nothing. */ const identityKey = e => unwrapValue(e);

/** Key equality for EVERY key comparison in this module (re-audit 2, P1-5):
 * SameValueZero, matching the Map-based matchers (buildRowOps, the adoption
 * window) — NaN keys are equal to themselves, so aligned NaN rows stay
 * aligned in the prefix walk instead of forever misaligning. Adoption and
 * row ops MUST agree on key equality or retained DOM rows go stale. */ function sameKey(e, n) {
    return e === n || e !== e && n !== n;
}

function emitSetterRowOps(e, n, t) {
    const o = buildIdentityRowOps(n, t);
    if (o !== null) rowHooks.emitRowOps(e, t, o);
}

/** Identity-keyed structural diff, returned rather than emitted: shared by
 * the setter channel (regular queue) and the OPTIMISTIC write channel (lane
 * queue) — same retention semantics, different dispatch timing. Returns
 * null when the lists are identity-aligned (no structure changed). */ function buildIdentityRowOps(e, n) {
    let t = 0;
    const o = e.length < n.length ? e.length : n.length;
    while (t < o && unwrapValue(e[t]) === unwrapValue(n[t])) t++;
    if (t === e.length && t === n.length) return null;
    return buildRowOps(e, n, t, identityKey);
}

/** Shared row-ops builder (keyed deep branch + shallow/positional branch):
 * key-matches the misaligned window into { prefix, sources, removed }.
 * `keyFn === null` degrades to positional ops (append/truncate only). */ function buildAndEmitRowOps(e, n, t, o, l) {
    rowHooks.emitRowOps(e, t, buildRowOps(n, t, o, l));
}

function buildRowOps(e, n, t, o) {
    const l = e.length;
    const i = n.length;
    const u = new Array(i - t);
    // Occurrence-aware matching (re-audit): duplicate keys queue their old
    // indices and each is consumed ONCE — first-wins reuse would hand the same
    // source (and its one DOM row) to multiple next positions. The no-dup fast
    // shape stays a bare number; collisions upgrade to a queue.
        let f = null;
    if (o !== null && t < l) {
        f = new Map;
        for (let n = t; n < l; n++) {
            const t = unwrapValue(e[n]);
            if (t !== null && typeof t === "object") {
                const e = o(t);
                if (e === undefined) continue;
                const l = f.get(e);
                if (l === undefined) f.set(e, n); else if (Array.isArray(l)) l.push(n); else f.set(e, [ l, n ]);
            }
        }
    }
    const s = f !== null ? new Set : null;
    for (let e = t; e < i; e++) {
        const l = n[e];
        let i = -1;
        if (l !== null && typeof l === "object" && f !== null) {
            const e = o(l);
            if (e !== undefined) {
                const n = f.get(e);
                if (n !== undefined) {
                    if (Array.isArray(n)) {
                        i = n.shift();
                        if (n.length === 1) f.set(e, n[0]);
                    } else {
                        i = n;
                        f.delete(e);
                    }
                    s.add(i);
                }
            }
        }
        u[e - t] = i;
    }
    const r = [];
    for (let n = t; n < l; n++) {
        if (s === null || !s.has(n)) r.push(unwrapValue(e[n]));
    }
    return {
        prefix: t,
        sources: u,
        removed: r
    };
}

function descend(e, n, t, o, l = false) {
    if (e === null || typeof e !== "object" || n === null || typeof n !== "object") return;
    // Lookup FIRST: a hit implies pv was wrappable and never raw-marked (only
    // wrappables acquire targets; rawValues never wrap) — one WeakMap get
    // replaces isWrappable(pv) + isRawValue(pv), and a miss prunes untracked
    // subtrees before any further checks.
        const i = (o?.map ?? storeNextLookup).get(e);
    if (i === undefined) return;
 // nothing proxied below this pair
    // The NEW side still validates fully: a frozen/platform/markRaw'd incoming
    // value is a leaf for reconcile — replaced by reference, never recursed
    // into (R42); the parent's slot notification covers the change.
        if (!isWrappable(n)) return;
    if (rawValuesUsed && isRawValue(n)) return;
    n = unwrapValue(n);
    // Kind change replaces wholesale, never merges (R10): a target's carrier
    // class (array vs object) is fixed at creation, so the slot detaches and a
    // fresh proxy of the right kind wraps the incoming value on next read.
        if (Array.isArray(e) !== Array.isArray(n)) return;
    if (t) {
        const o = t(e);
        const l = t(n);
        // Key mismatch detaches: the slot takes the new entity; the old proxy
        // keeps its (old) backing and a fresh proxy wraps the new value on read.
        // SameValueZero (re-audit 2, P1-5): NaN keys are self-equal — strict
        // inequality detached every NaN-keyed slot on every tick while the
        // Map-based row-ops matcher retained its DOM row (stale forever).
                if (o !== undefined && l !== undefined && !sameKey(o, l)) return;
    }
    // Reachability pruning (§6d) is MODE-dependent, both pinned:
    // - keyed matching descends only where subscriptions exist at/below (`d`) —
    //   captured-but-unobserved proxies deliberately detach and go stale
    //   (recon-snap R18; subscribing is what buys liveness);
    // - positional (key: null) pairing preserves slot identity unconditionally
    //   (recon-snap R8 — the fixed-shape dashboard pattern).
    // Projection merges (replace mode) preserve key-matched identity
    // UNCONDITIONALLY (proj R6: the slot keeps its proxy without needing a
    // subscriber below); plain keyed reconcile detaches unobserved captures
    // (recon-snap R18 — staleness is the pinned pruning contract).
        if (!l && t !== null && !i.d) return;
    applyAdopt(i, n, t, l);
}

export { buildIdentityRowOps, emitSetterRowOps, reconcileNextState, sameKey };