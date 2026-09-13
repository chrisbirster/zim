import "../core/core.js";

import { SUPPORTS_PROXY } from "../core/constants.js";

import "../core/scheduler.js";

import "../core/invariants.js";

import "../core/verdict.js";

import "../core/effect.js";

import { createMemo } from "../signals.js";

import { ownEnumerableKeys, $PROXY } from "./store.js";

function trueFn() {
    return true;
}

const propTraps = {
    get(e, r, t) {
        if (r === $PROXY) return t;
        return e.get(r);
    },
    has(e, r) {
        if (r === $PROXY) return true;
        return e.has(r);
    },
    set: trueFn,
    deleteProperty: trueFn,
    getOwnPropertyDescriptor(e, r) {
        return {
            configurable: true,
            enumerable: true,
            get() {
                return e.get(r);
            },
            set: trueFn,
            deleteProperty: trueFn
        };
    },
    ownKeys(e) {
        return e.keys();
    }
};

function resolveSource(e) {
    return !(e = typeof e === "function" ? e() : e) ? {} : e;
}

const $SOURCES = Symbol(0);

/**
 * Merges multiple props-like objects into a single proxy that *preserves
 * reactivity*. Reads are forwarded to the right-most source that defines the
 * property, so later sources override earlier ones (like `Object.assign`).
 *
 * Function arguments are treated as memo-backed sources — useful for passing
 * derived defaults whose computation should track reactively.
 *
 * Use this in component bodies to merge defaults / overrides without losing
 * Solid's per-property tracking.
 *
 * @example
 * ```tsx
 * function Button(_props: { label: string; type?: string; disabled?: boolean }) {
 *   const props = merge({ type: "button", disabled: false }, _props);
 *
 *   return <button type={props.type} disabled={props.disabled}>{props.label}</button>;
 * }
 * ```
 */ function merge(...e) {
    if (e.length === 1 && typeof e[0] !== "function") return e[0];
    let r = false;
    const t = [];
    for (let n = 0; n < e.length; n++) {
        const o = e[n];
        r = r || !!o && $PROXY in o;
        const s = !!o && o[$SOURCES];
        if (s) {
            for (let e = 0; e < s.length; e++) t.push(s[e]);
        } else t.push(typeof o === "function" ? (r = true, createMemo(o)) : o);
    }
    if (SUPPORTS_PROXY && r) {
        return new Proxy({
            get(e) {
                if (e === $SOURCES) return t;
                for (let r = t.length - 1; r >= 0; r--) {
                    const n = resolveSource(t[r]);
                    if (e in n) return n[e];
                }
            },
            has(e) {
                for (let r = t.length - 1; r >= 0; r--) {
                    if (e in resolveSource(t[r])) return true;
                }
                return false;
            },
            keys() {
                const e = new Set;
                for (let r = 0; r < t.length; r++) {
                    const n = ownEnumerableKeys(resolveSource(t[r]));
                    for (let r = 0; r < n.length; r++) e.add(n[r]);
                }
                return [ ...e ];
            }
        }, propTraps);
    }
    const n = Object.create(null);
    let o = false;
    let s = t.length - 1;
    for (let e = s; e >= 0; e--) {
        const r = t[e];
        if (!r) {
            e === s && s--;
            continue;
        }
        const u = Object.getOwnPropertyNames(r);
        for (let t = u.length - 1; t >= 0; t--) {
            const c = u[t];
            if (c === "__proto__" || c === "constructor") continue;
            if (!n[c]) {
                o = o || e !== s;
                const t = Object.getOwnPropertyDescriptor(r, c);
                n[c] = t.get ? {
                    enumerable: true,
                    configurable: true,
                    get: t.get.bind(r)
                } : t;
            }
        }
    }
    if (!o) return t[s];
    const u = {};
    const c = Object.keys(n);
    for (let e = c.length - 1; e >= 0; e--) {
        const r = c[e], t = n[r];
        if (t.get) Object.defineProperty(u, r, t); else u[r] = t.value;
    }
    u[$SOURCES] = t;
    return u;
}

/**
 * Returns a reactive proxy of `props` with the listed keys hidden. Tracking
 * on the remaining keys is preserved.
 *
 * Use it to forward "rest" props to a child element while pulling out the
 * keys your component handles itself — the equivalent of `splitProps(p, ["a","b"])[1]`.
 *
 * @example
 * ```tsx
 * function Input(props: { label: string; value: string; onInput: (v: string) => void } & JSX.HTMLAttributes<HTMLInputElement>) {
 *   const rest = omit(props, "label", "value", "onInput");
 *
 *   return (
 *     <label>
 *       {props.label}
 *       <input
 *         {...rest}
 *         value={props.value}
 *         onInput={e => props.onInput(e.currentTarget.value)}
 *       />
 *     </label>
 *   );
 * }
 * ```
 */ function omit(e, ...r) {
    if (SUPPORTS_PROXY && $PROXY in e) {
        return new Proxy({
            get(t) {
                // $SOURCES must not tunnel through the filter: merge() flattens
                // whatever answers it, so forwarding would hand a re-merge the
                // UNFILTERED sources of an underlying merge proxy and the omitted
                // keys leak back in (#3014 — the SSR element-spread path re-merges
                // static attributes with the rest object). Opaque here: merge
                // composes omit proxies through their traps instead.
                return t === $SOURCES || r.includes(t) ? undefined : e[t];
            },
            has(t) {
                return t !== $SOURCES && !r.includes(t) && t in e;
            },
            keys() {
                return ownEnumerableKeys(e).filter(e => !r.includes(e));
            }
        }, propTraps);
    }
    const t = {};
    const n = Object.getOwnPropertyNames(e);
    const o = r.length > 4 && n.length > r.length ? new Set(r) : undefined;
    for (const s of n) {
        if (o ? !o.has(s) : !r.includes(s)) {
            const r = Object.getOwnPropertyDescriptor(e, s);
            !r.get && !r.set && r.enumerable && r.writable && r.configurable ? t[s] = r.value : Object.defineProperty(t, s, r);
        }
    }
    return t;
}

export { merge, omit };