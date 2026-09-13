# ADR 0001: QuickJS runtime

- Status: accepted
- Date: 2026-08-29
- Engine: official QuickJS `2026-06-04`

## Decision

Hondo uses the official QuickJS `2026-06-04` release as its JavaScript runtime.

Release pin:

```text
https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz
SHA-256: b376e839b322978313d929fd20663b11ba58b75df5a46c126dd19ea2fa70ad2a
Git commit: 04be246001599f5995fa2f2d8c91a0f198d3f34c
```

The Zig package dependency uses that exact Bellard Git commit and its Zig package hash. Hondo does not expose a public multi-engine abstraction. Application code targets Solid 2 + Hondo; QuickJS is an implementation detail behind the Zig runtime boundary.

## Runtime boundary

```text
Solid 2 application
        ↓
@solidjs/universal
        ↓
@hondo/solid
        ↓
Hondo host mutations
        ↓
official QuickJS 2026-06-04
        ↓
Zig runtime / terminal engine
```

QuickJS owns JavaScript execution only. It does not own terminal raw mode, input decoding, layout, the cell grid, terminal output, PTYs, editor buffers, Tree-sitter, LSP, or other native application state.

## Dependency and build strategy

The official release/archive identity is the source of truth. Hondo will not track QuickJS `master` implicitly and will not vendor an unversioned engine snapshot.

Hondo fetches the exact Bellard release commit through Zig's package manager and compiles the QuickJS engine C sources with Zig itself. This avoids making QuickJS's Unix-oriented Makefile part of Hondo's build contract and gives Hondo one native build path for Linux, macOS, and Windows.

The embedded engine library initially contains only the core sources Hondo needs:

```text
quickjs.c
dtoa.c
libregexp.c
libunicode.c
cutils.c
```

`quickjs-libc.c` is intentionally excluded from the embedded core. Hondo does not need the `qjs` shell's filesystem/OS helper library to execute bundled Solid applications, and terminal/filesystem/process ownership remains in Zig.

Engine-specific `JSRuntime`, `JSContext`, and `JSValue` details remain inside `zig/src/runtime/quickjs.zig` and must not leak into public Hondo component or host-node APIs.

The adapter owns:

- runtime/context creation and destruction;
- JavaScript evaluation;
- exception extraction/reporting;
- QuickJS pending-job draining for Promises/microtasks.

## Why this engine

- small, embeddable C API that fits a Zig-owned runtime;
- current official release supports the ECMAScript features required by Solid 2;
- no C++/JSI layer is required;
- the same release has already demonstrated Solid 2 fine-grained renderer semantics in a separate native-runtime implementation;
- Hondo needs one dependable engine, not a permanent engine bake-off.

## Upgrade policy

A QuickJS upgrade is an explicit dependency change. It must update the release pin/checksum/commit/package hash, pass Hondo's JavaScript semantics and renderer tests, and pass cross-platform Zig builds before merging to `dev`.
