# Solid 2 baseline

Hondo targets **Solid 2 only**.

The authoritative documentation baseline is:

- https://v2.solidjs.com

Hondo does not target Solid 1.x compatibility and must not use the Solid 1.x `solid-js/universal` subpath. Solid 2 publishes the custom-renderer primitive as the separate `@solidjs/universal` package.

## Coordinated RC baseline

Hondo pins the Solid runtime and universal renderer to the **same RC train**.

Current baseline:

```text
solid-js             2.0.0-rc.4
@solidjs/universal   2.0.0-rc.4
```

Solid published this coordinated pair on 2026-08-28. Renderer/runtime RCs must not be mixed: the universal runtime depends on the matching Solid reactive/effect semantics, and RC releases may change that seam.

## Rules

- Do not add Solid 1.x compatibility shims.
- Do not import the Solid 1.x `solid-js/universal` entrypoint.
- Use `@solidjs/universal` for Hondo's renderer.
- Follow `v2.solidjs.com` semantics for components, control flow, reactivity, rendering, and migration decisions.
- Pin Solid prerelease versions during Hondo pre-alpha development so upstream changes cannot silently alter renderer semantics.
- Keep `solid-js` and `@solidjs/universal` on the same coordinated RC version.
- Upgrading the Solid RC baseline requires Hondo renderer conformance tests to pass on Linux, macOS, and Windows before merging to `dev`.

Solid's DOM/web renderer is not part of Hondo's runtime architecture.
