import { STATUS_UNINITIALIZED, CONFIG_CHILD_COMPANIONS, STATUS_ERROR, STATUS_PENDING, REACTIVE_DIRTY, REACTIVE_OPTIMISTIC_DIRTY, NOT_PENDING, CONFIG_AUTO_DISPOSE, REACTIVE_ZOMBIE, REACTIVE_DISPOSED } from "./constants.js";

import { untrack, ext, statusNotifierOf, setSignal, context } from "./core.js";

import "./invariants.js";

import { StatusError, NotReadyError } from "./error.js";

import { trimStaleDeps, unobserved } from "./graph.js";

import { enqueueSub } from "./heap.js";

import { hasActiveOverride, assignOrMergeLane, resolveLane, resolveTransition } from "./lanes.js";

import { cleanup } from "./owner.js";

import { GlobalQueue, schedule, flush, queuePendingNode, insertSubs, clock, currentTransition, globalQueue } from "./scheduler.js";

// The lazily-created Set is the ONE container for pending sources. Its
// predecessor — a singular slot promoted to a Set on the second source —
// created dual state whose migration invariant was easy to break: a third
// overlapping source landed beside the Set and removePendingSource refused
// to clear it, stranding the Set members' pending forever (#2893).
function addPendingSource(e, n) {
    if (e.o?.le?.has(n)) return false;
    (ext(e).le ??= new Set).add(n);
    return true;
}

function removePendingSource(e, n) {
    if (!e.o?.le?.delete(n)) return false;
    if (e.o?.le.size === 0) if (e.o !== null) e.o.le = undefined;
    return true;
}

function clearPendingSources(e) {
    e.o?.le?.clear();
    if (e.o !== null) e.o.le = undefined;
}

/**
 * A loading-window node hit an unready source (sync throw in recompute, or a
 * NotReadyError-rejected flight): register for the source's settle — the
 * settlePendingSource walk runs off `_pendingSources` + `_blocked` alone —
 * with NO read-visible pending status, no downstream propagation, no
 * transition, no lane registration. Commit #0 keeps serving.
 */ function parkLoadingWindow(e, n) {
    ext(e).fe = true;
    if (n.source) addPendingSource(e, n.source);
    // A settled error is the node's answer ("the error stays the answer until
    // this retry can actually run") — the park must not replace it: reads
    // throw `_error` while STATUS_ERROR is set, and overwriting it here leaks
    // a pending-class NotReadyError from a read-invisible park (#2989).
        if (!(e.S & STATUS_ERROR)) setPendingError(e, n.source, n);
}

function setPendingError(e, n, t) {
    if (!n) {
        if (e.o !== null) e.o._ = null;
        return;
    }
    if (t instanceof NotReadyError && t.source === n) {
        ext(e)._ = t;
        return;
    }
    const r = e.o?._;
    if (!(r instanceof NotReadyError) || r.source !== n) {
        ext(e)._ = new NotReadyError(n);
    }
}

function forEachDependent(e, n) {
    for (let t = e.u; t !== null; t = t.ae) n(t.ce, t);
    // `?? null`: affects() marks route plain signals (no `_child` slot) through here.
        for (let t = e.o?.i ?? null; t !== null; t = t.Se) {
        for (let e = t.u; e !== null; e = e.ae) n(e.ce, e);
    }
}

// Queue a node to re-run on the next flush (used both when a pending source
// settles and when an `isPending` observer must re-evaluate after a real error):
// shared scheduling helper in heap.ts (tracked effects bypass the heap).
// Settle-time counterpart of unlinkSubs' last-one-out check. A lazy node that
// loses its last subscriber while STATUS_PENDING is exempt from autodispose
// (the in-flight work is an observer), so whatever CLEARS that pending state
// must run the release — otherwise the node stays linked and recomputes
// forever with zero subscribers (#2934). The node's own promise/iterator
// callbacks handle their own release (settleAutodispose in handleAsync); this
// covers derivatively-pending dependents, which have no callbacks of their own.
function releaseIfSettledUnobserved(e) {
    e.oe && e.T & CONFIG_AUTO_DISPOSE && !e.u && !(e.ie & REACTIVE_ZOMBIE) && !(e.S & STATUS_PENDING) && unobserved(e);
}

// Error-path sweep: notifyStatus(STATUS_ERROR) clears dependents' pending
// sources through its own recursion (no per-node settle callback), so after
// the propagation completes, walk the same graph for stranded lazy nodes.
// Collect-then-release so unobserved() never unlinks under the walk.
function releaseSettledDependents(e) {
    let n;
    const t = new Set;
    const visit = e => {
        if (t.has(e)) return;
        t.add(e);
        if (!e.u && e.T & CONFIG_AUTO_DISPOSE) (n ??= []).push(e);
        forEachDependent(e, visit);
    };
    forEachDependent(e, visit);
    if (n) for (const e of n) releaseIfSettledUnobserved(e);
}

// Error-dimension twin of settlePendingSource's blocked re-enqueue (#2949):
// a node in STATUS_ERROR that recovers by recomputing to an UNCHANGED value
// fires no value notification — the recovery is completely silent. But a
// dependent that re-ran during the error window consumed its dirty flag and
// committed nothing (the fresh sibling values it read were absorbed into an
// errored run), so its committed value is stale. The propagated error is one
// object identity down the whole dependent tree, and holding it is exactly
// the "blocked on this error" marker — re-enqueue those holders so they
// re-run: fresh values commit and flow, and a dependent with another
// still-broken source simply re-errors. The async dimension needs no twin of
// its own: recovery there passes through a pending window whose re-runners
// set _blocked and ride settlePendingSource. Walks the full dependent graph
// (releaseSettledDependents shape): identity holders can sit below an
// intermediate whose own error state has since been scrubbed or replaced
// (e.g. an error boundary's tree node).
function settleErroredDependents(e, n) {
    let t = false;
    const r = new Set;
    const visit = e => {
        if (r.has(e)) return;
        r.add(e);
        if (e.o?._ === n) {
            enqueueSub(e);
            t = true;
        }
        forEachDependent(e, visit);
    };
    forEachDependent(e, visit);
    if (t) schedule();
}

function settlePendingSource(e) {
    let n = false;
    let t;
    const r = new Set;
    // Companion updates no-op without the verdict layer (null hook).
        const o = GlobalQueue.de;
    const settle = l => {
        if (r.has(l) || !removePendingSource(l, e)) return;
        r.add(l);
        l.Te = clock;
        const i = l.o?.le?.values().next().value;
        // STATUS_ERROR + pending sources only coexist via an errored loading
        // window's park (notifyStatus(STATUS_ERROR) clears pending sources
        // otherwise): the settled error stays the answer through the settle —
        // nulling it here would have reads throw `null` until the re-enqueued
        // retry lands, or lose it entirely if that retry parks again (#2989).
                const u = l.S & STATUS_ERROR;
        if (i) {
            if (!u) setPendingError(l, i);
            o !== null && o(l);
        } else {
            l.S &= ~STATUS_PENDING;
            if (!u) setPendingError(l);
            o !== null && o(l);
            if (l.o?.fe) {
                enqueueSub(l);
                n = true;
            }
            if (l.o !== null) l.o.fe = false;
            // Fully settled with nobody watching: release candidate (#2934). Checked
            // again at release time — deferred so unobserved() can't unlink subs
            // lists this walk is still iterating.
                        if (!l.u && l.T & CONFIG_AUTO_DISPOSE) (t ??= []).push(l);
        }
        forEachDependent(l, settle);
    };
    forEachDependent(e, settle);
    // Release before the flush schedule below: unobserved() pulls the node back
    // out of the heap, so the enqueueSub above never recomputes a released node.
        if (t) for (const e of t) releaseIfSettledUnobserved(e);
    if (n) schedule();
}

// Object-thenable detection (Promises/A+ shape).
function isThenable(e) {
    return e != null && typeof e === "object" && typeof e.then === "function";
}

function handleAsync(e, n, t) {
    let r = false;
    let o = false;
    if (typeof n === "object" && n !== null) {
        untrack(() => {
            r = n[Symbol.asyncIterator];
            o = !r && isThenable(n);
        });
    }
    if (!o && !r) {
        if (e.o !== null) e.o.Ee = null;
        // A sync landing is the first real answer for a loadingValue node.
                e.Ie = false;
        return n;
    }
    ext(e).Ee = n;
    let l;
    // Settle-time transition re-entry. The loading rail is invisible to
    // transactions (#2933): a boundary-caught first load never registers as an
    // async reporter, so its settle — the boundary's fallback -> content
    // reveal — must flow ambiently. The node can still carry a `_transition`
    // stamp (pending-node bookkeeping rides through the stamping sites), and
    // blindly re-entering that stamped, still-incomplete transaction stashed
    // the reveal with it — a deadlock when the transaction's completion
    // depended on the reveal (#2937). An ESCAPED first load did register and
    // keeps transition scheduling; initialized (value-holding) pending settles
    // are the transaction's reveal machinery and always re-enter.
        const settleTransition = () => {
        const n = resolveTransition(e);
        if (n && e.S & STATUS_UNINITIALIZED && !currentTransition(n).Ne.has(e)) {
            // Drop the stale stamp too: the plain settle write (setSignal) and the
            // stash-path restamp both re-enter the transaction through it.
            e._e = null;
            return;
        }
        globalQueue.initTransition(n);
    };
    const handleError = t => {
        if (e.o?.Ee !== n) return;
        // NotReadyError from rejected promises should be treated as pending, not error
                let r = t instanceof NotReadyError;
        if (r && e.Ie) {
            // Loading window: the flight died waiting on an unready source. Keep
            // serving commit #0 — same parking as recompute's catch for sync
            // dependency throws. The dead flight is released so the clock-gated
            // error-retry pull (updateIfNecessary) can also re-ask.
            if (e.o !== null) e.o.Ee = null;
            parkLoadingWindow(e, t);
            e.Te = clock;
            return;
        }
        settleTransition();
        notifyStatus(e, r ? STATUS_PENDING : STATUS_ERROR, t);
        e.Te = clock;
        // A real error settles derivatively-pending dependents (notifyStatus
        // cleared their pending sources), so stranded lazy ones release here —
        // the error twin of settlePendingSource's release (#2934).
                if (!r) releaseSettledDependents(e);
    };
    const asyncWrite = (r, o) => {
        if (e.o?.Ee !== n) return;
        // If the node was dirtied by a newer write (optimistic override or regular),
        // skip this stale async result — the upcoming flush will recompute the node
        // with the new value, creating a fresh Promise that supersedes this one.
                if (e.ie & (REACTIVE_DIRTY | REACTIVE_OPTIMISTIC_DIRTY)) return;
        settleTransition();
        const l = !!(e.S & STATUS_UNINITIALIZED);
        trimStaleDeps(e);
        clearStatus(e);
        const i = resolveLane(e);
        if (i) i.Ae.delete(e);
        if (t) {
            t(r);
            if (l) clearStatus(e, true);
        } else if (e.o?.De !== undefined) {
            // Optimistic node — resting OR covered by an active override — holds
            // through the shared pending-node path, exactly like a plain async memo,
            // so the commit clears STATUS_UNINITIALIZED (#2806) and elevation to
            // _value happens on this value's OWN transition schedule (A18 as
            // re-ruled 2026-07-07: _value only changes at commit points). With an
            // override active the hold and its eventual commit are unobservable
            // (A17 — every reader sees the override); the revert reveals whatever
            // has committed by then, so corrections reveal atomically with their
            // transition rather than escaping it.
            if (e.Pe === NOT_PENDING) queuePendingNode(e);
            e.Pe = r;
            // The hold is a companion-visible write like any other (A13/A19): the
            // clearStatus() above computed its verdict before the hold existed, so
            // isPending must re-derive (the value is not final until commit — V1)
            // and latest() must see the fresh in-flight value (V2). Subscribers are
            // only notified when the hold is visible to them: under an active
            // override every reader sees the override (A17), so waking subs would
            // re-show an unchanged view — the revert is the notification point.
                        GlobalQueue.Oe !== null && GlobalQueue.Oe(e, r);
            if (!hasActiveOverride(e)) {
                insertSubs(e);
            }
            e.Te = clock;
        } else if (i) {
            // Route through lane's effect queue for independent flushing
            const n = e.Re;
            const t = e.be;
            const o = e.Ue;
            try {
                if (!n && l || !o || !o(r, t)) {
                    e.be = r;
                    e.Te = clock;
                    // The latest() shadow write gives latest() effects independent lanes; the
                    // _pendingSignal update is a no-op repeat of the clearStatus() call above
                    // (computePendingState doesn't read _value).
                                        GlobalQueue.Oe !== null && GlobalQueue.Oe(e, r);
                    insertSubs(e, true);
                }
            } catch (n) {
                // A user comparator throwing during async resolution has no caller to
                // surface to (we're in promise machinery) — route it through the node's
                // error status so boundaries contain it instead of an unhandled
                // rejection (#2837).
                notifyStatus(e, STATUS_ERROR, n);
            }
        } else {
            try {
                setSignal(e, () => r);
            } catch (n) {
                // Same containment as above: setSignal's comparator throw is the only
                // pre-commit failure here, and there is no user callsite to throw to.
                notifyStatus(e, STATUS_ERROR, n);
            }
        }
        // First real answer landing: the window closes when the answer becomes
        // OBSERVABLE. A direct commit is observable now; a transition-held write
        // (`_pendingValue` set above or inside setSignal) is not — the verdict's
        // held-value branch is window-gated, and commitPendingNode closes the
        // window when the hold commits, so no one-frame isPending pulse can leak
        // to live observers between the landing and its commit (#2990).
                if (e.Pe === NOT_PENDING) e.Ie = false;
        settlePendingSource(e);
        schedule();
        flush();
        o?.();
    };
    // A pending node's in-flight promise is an observer: `unlinkSubs` skips
    // autodispose while STATUS_PENDING so subscriber churn can't orphan the
    // work (a lazy async memo would otherwise tear down and re-execute — one
    // fetch per suspended re-read). Settling is that observer's release, so
    // it runs the same last-one-out check the other release sites run.
    // Returns whether the node released, so the iterator branch can stop
    // pulling values instead of pumping an unobserved stream forever (#2935).
        const settleAutodispose = () => {
        if (e.T & CONFIG_AUTO_DISPOSE && !e.u && !(e.S & STATUS_PENDING)) {
            unobserved(e);
            return true;
        }
        return false;
    };
    // Consumes an AsyncIterable as this flight's value stream. Two postures:
    // LIVE (called synchronously from this read — the compute returned an
    // iterable directly, or a sync-settled thenable held one), where the
    // initial drain may stash a sync first yield for the caller to return and
    // close registration uses the ambient owner; and DEFERRED (the flattening
    // path — a thenable resolved to an iterable in a later microtask), where
    // there is no caller to serve and no ambient owner: sync-settled steps
    // write through asyncWrite, and close registration goes through the slot
    // the thenable branch pre-registered while it still owned the context.
    // Returns whether a sync answer landed (first yield or empty completion) —
    // meaningful only in the live posture.
        const consumeIterator = (t, r) => {
        const o = t[Symbol.asyncIterator]();
        let i = false;
        let u = false;
        let s = !r;
        const close = () => {
            if (u) return;
            u = true;
            try {
                const e = o.return?.();
                if (isThenable(e)) e.then(undefined, () => {});
            } catch {}
        };
        r ? r(close) : cleanup(close);
        // Release check before each next pull: an unobserved lazy node must tear
        // down (its close above runs via disposal, closing the iterator) instead
        // of pumping the stream forever with zero subscribers (#2935).
                const iterateOrRelease = () => {
            if (!settleAutodispose()) iterate();
        };
        const iterate = () => {
            let t, r, f = false, a = false, c = true;
            // Protocol tolerance, matching `for await`: `await` unwraps whatever
            // next() returns — a thenable OR a bare IteratorResult. Real producers
            // use the bare form as a promise-free fast path when a value is already
            // buffered (seroval's deserialized streams do), so a bare result is
            // assimilated as an already-settled step instead of crashing on `.then`.
                        const S = o.next();
            const d = isThenable(S) ? S : {
                then: e => void e(S)
            };
            d.then(r => {
                // The sync stash only serves the INITIAL drain (handleAsync's caller
                // consumes syncValue / throws NotReady from it). A sync-settled step
                // after an async gap — seroval buffering values between pulls, a
                // sync-thenable producer mid-stream — has no caller reading the
                // stash: it must write through the async path or the value is
                // silently dropped. (The deferred posture never has a caller, so
                // initialRead starts false there and everything writes through.)
                if (c && s) {
                    t = r;
                    f = true;
                    if (r.done) u = true;
                } else if (e.o?.Ee !== n) {
                    return;
                } else if (!r.done) {
                    i = true;
                    asyncWrite(r.value, iterateOrRelease);
                } else {
                    u = true;
                    if (i) {
                        schedule();
                        flush();
                    } else {
                        // Empty completion settles like the immediately-done sync path.
                        asyncWrite(undefined);
                    }
                    settleAutodispose();
                }
            }, t => {
                if (c && s) {
                    r = t;
                    a = true;
                } else if (e.o?.Ee === n) {
                    u = true;
                    handleError(t);
                    settleAutodispose();
                }
            });
            c = false;
            if (a) {
                // Match the promise branch, but only rethrow during the initial read.
                u = true;
                handleError(r);
                if (s) throw r;
                return true;
            }
            if (f && !t.done) {
                l = t.value;
                i = true;
                return iterate();
            }
            return f && t.done;
        };
        const f = iterate();
        // Later iterate() calls run from asyncWrite, where rethrowing would be unhandled.
                s = false;
        return i || f;
    };
    // Landed-synchronously verdict for a LIVE iterator drain; null when no live
    // drain ran (plain promise flight, or a deferred flatten). Drives the
    // shared NotReady/loading tail below.
        let i = null;
    // Flatten one async level: a thenable that RESOLVES to an AsyncIterable —
    // the shape every async stub returning a stream produces — consumes as the
    // stream itself rather than settling on the iterable object. One level
    // only: A+ `then` already collapses nested thenables, so the resolved
    // value is never itself a thenable.
        const flattenIfIterable = (e, n) => {
        let t = false;
        if (typeof e === "object" && e !== null) {
            untrack(() => {
                t = e[Symbol.asyncIterator];
            });
        }
        if (!t) return false;
        const r = consumeIterator(e, n);
        if (!n) i = r;
        return true;
    };
    if (o) {
        let t = false, r = false, o, i = true;
        // Close registration for the flattening path. Consumption starts in a
        // microtask where the ambient owner is gone (or worse, someone else's),
        // so `cleanup()` can't be used — the close targets el's disposal list
        // directly, exactly where a live cleanup() during this recompute would
        // have put it. Deliberately NOT pre-registered at flight start: a
        // non-null `_disposal` reclassifies the node into recompute's deferred
        // (zombie) disposal path, and plain promise flights — the overwhelming
        // majority — must not pay that. Only a flight that actually flattens
        // becomes disposal-bearing, which is exactly the class a directly
        // returned iterable already occupies.
                const registerDeferredClose = n => {
            if (!e.he) e.he = n; else if (Array.isArray(e.he)) e.he.push(n); else e.he = [ e.he, n ];
        };
        n.then(r => {
            if (i) {
                l = r;
                t = true;
            } else if (e.o?.Ee === n && !(e.ie & REACTIVE_DISPOSED) && flattenIfIterable(r, registerDeferredClose)) ; else {
                asyncWrite(r);
                settleAutodispose();
            }
        }, e => {
            if (i) {
                o = e;
                r = true;
            } else {
                handleError(e);
                settleAutodispose();
            }
        });
        i = false;
        if (r) {
            // Settle through the same status path an async rejection uses, then
            // unwind the in-progress synchronous read so the errored node isn't
            // momentarily read as `undefined`.
            handleError(o);
            throw o;
        } else if (!t) {
            // Loading window: serve commit #0 instead of suspending. No transition
            // is opened — first-flight work on a loadingValue node is loading-class
            // (invisible to boundaries and transitions); the flight itself is
            // already registered in _inFlight and lands through asyncWrite.
            if (e.Ie) return e.be;
            globalQueue.initTransition(resolveTransition(e));
            throw new NotReadyError(context);
        } else if (!flattenIfIterable(l)) {
            // Synchronously-resolved promise: the first real answer landed.
            e.Ie = false;
        }
        // A sync-resolved promise holding an AsyncIterable flattened LIVE (we
        // are still inside the synchronous read): full initial-drain semantics
        // apply and the shared tail below settles the verdict.
        }
    if (r) flattenIfIterable(n);
    if (i !== null) {
        if (!i) {
            // Loading window: serve commit #0 (see the promise branch above).
            if (e.Ie) return e.be;
            globalQueue.initTransition(resolveTransition(e));
            throw new NotReadyError(context);
        }
        // A sync first yield (or immediate empty completion) is the first real
        // answer; async yields clear inside asyncWrite.
                e.Ie = false;
    }
    return l;
}

function clearStatus(e, n = false) {
    if (e.o?.le) clearPendingSources(e);
    if (e.o?.fe) if (e.o !== null) e.o.fe = false;
    // The pending window is over; its quiet classification dies with it.
    // (Unconditional: _reask is baked into the node literals, so this is a
    // plain store to an existing slot — no shape change.)
        if (e.o !== null) e.o.pe = false;
    e.S = n ? 0 : e.S & STATUS_UNINITIALIZED;
    if (e.o?._) setPendingError(e);
    // Update pending signal for isPending() reactivity (companions only exist
    // once the verdict layer created them, which installs the hooks).
        if (e.o?.Ge || e.o?.ge) GlobalQueue.de(e);
    if (e.o?.i && e.T & CONFIG_CHILD_COMPANIONS && GlobalQueue.ye !== null) GlobalQueue.ye(e);
    const t = statusNotifierOf(e);
    if (t) t.call(e);
}

function notifyStatus(e, n, t, r, o) {
    // Wrap regular errors to track source node
    if (n === STATUS_ERROR && !(t instanceof StatusError) && !(t instanceof NotReadyError)) t = new StatusError(e, t);
    const l = n === STATUS_PENDING && t instanceof NotReadyError ? t.source : undefined;
    const i = l === e;
    const u = n === STATUS_PENDING && e.o?.De !== undefined && !i;
    const s = u && hasActiveOverride(e);
    if (!r) {
        if (n === STATUS_PENDING && l) {
            addPendingSource(e, l);
            e.S = STATUS_PENDING | e.S & STATUS_UNINITIALIZED;
            // Preserve the current source on this propagation so render-effect notification
            // can register every distinct pending source with the transition.
                        setPendingError(e, l, t);
        } else {
            clearPendingSources(e);
            e.S = n | (n !== STATUS_ERROR ? e.S & STATUS_UNINITIALIZED : 0);
            ext(e)._ = t;
        }
        GlobalQueue.de !== null && GlobalQueue.de(e);
        if (e.o?.i && e.T & CONFIG_CHILD_COMPANIONS && GlobalQueue.ye !== null) GlobalQueue.ye(e);
    }
    if (o && !r) {
        assignOrMergeLane(e, o);
    }
    const f = r || s;
    const a = r || u ? undefined : o;
    const c = statusNotifierOf(e);
    if (c) {
        if (r && n === STATUS_PENDING) {
            return;
        }
        if (f) {
            c.call(e, n, t);
        } else {
            c.call(e);
        }
        return;
    }
    forEachDependent(e, (e, r) => {
        e.Te = clock;
        if (n === STATUS_PENDING && l && !e.o?.le?.has(l) || n !== STATUS_PENDING && (e.o?._ !== t || e.o?.le)) {
            // A pending-observer link is the subscription an `isPending` read created.
            // It exists so the observer re-runs when the source settles, but it must
            // not carry a real (non-NotReadyError) error — the synchronous `isPending`
            // read swallows those, and the async path must match. Re-run the observer
            // so `isPending` re-evaluates (to not-pending) instead of forwarding.
            if (r.me && n !== STATUS_PENDING && !(t instanceof NotReadyError)) {
                enqueueSub(e);
                schedule();
                return;
            }
            if (!f && !e._e) queuePendingNode(e);
            notifyStatus(e, n, t, f, a);
        }
    });
}

export { addPendingSource, clearStatus, forEachDependent, handleAsync, isThenable, notifyStatus, parkLoadingWindow, releaseSettledDependents, setPendingError, settleErroredDependents, settlePendingSource };