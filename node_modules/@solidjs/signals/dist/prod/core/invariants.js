import "./core.js";

/**
 * INV-2: a node with an *active* override must be registered for reversion in
 * the queue's or a transition's `_optimisticNodes`. An unregistered active
 * override would survive transition completion forever. Runs at the end of
 * every flush (not just quiescence — the invariant holds mid-transition).
 * (There is no revert-target requirement: authoritative values commit
 * silently into `_value` under the override mask — A17 — so reverting is
 * just dropping the override.)
 */ function devCheckActiveOverrides(e) {
    return;
}

/** INV-1: an isPending() probe must never leak past its own call. */ function devCheckFlushStart() {
    return;
}

/**
 * Companion-vs-oracle census (#2838 pre-work). A NON-ASSERTING diff logger:
 * at the end of every flush it compares each live companion's cached state
 * against a fresh oracle and logs every distinct divergence fingerprint once
 * (console, `[census]` prefix). Legit lane-scoped windows will show up too —
 * the census exists to enumerate the full taxonomy of mid-flight divergence
 * so the write-driven redesign knows every case it must produce, not to
 * judge them. Enabled only when the COMPANION_CENSUS env var is set (in
 * addition to `false`), so normal test runs pay one boolean check.
 */ typeof globalThis !== "undefined" && !!globalThis.process?.env?.COMPANION_CENSUS;

function devCensusCompanions(e) {
    return;
}

/**
 * Quiescence checks. Run only when the system is fully drained: nothing
 * scheduled, no active/stashed transitions, no live lanes. At that point no
 * transition-scoped state may survive, and the lazily-created companions must
 * agree with a fresh computation of their owner's state.
 */ function devCheckQuiescent(e) {
    return;
}

export { devCensusCompanions, devCheckActiveOverrides, devCheckFlushStart, devCheckQuiescent };