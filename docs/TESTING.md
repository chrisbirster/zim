# Testing Zim

Zim v1 uses layered tests because no single test surface can prove a terminal modal editor is correct. In particular, a headless editor unit test cannot prove terminal key decoding or Hondo/native-view focus routing, while a PTY end-to-end test is too slow and coarse to replace focused unit coverage.

## Test layers

### 1. Zig core unit tests

Fast tests for editor semantics and protocol-independent behavior:

```bash
zig build test-core -Dheadless-only=true
```

This layer owns modal grammar, motions, counts, operators, text objects, registers, undo/redo, marks and jumps, buffers, windows/tabs, command parsing, tree state, session/recovery logic, and pure protocol machinery.

### 2. Solid/Hondo UI state unit tests

Pure TypeScript tests for state derived from the native editor payload and terminal chrome rules:

```bash
npm run test:ui
```

This layer covers dashboard visibility, native payload validation, Pins/Harpoon payloads, popup payloads, context summaries, and context navigation. Vitest is intentionally used here without a browser or DOM. Zim is a terminal application, so Playwright is not a v1 dependency.

### 3. Zig + Hondo integration tests

Tests that embed the actual Hondo runtime and prove that native editor state and UI actions cross the Zig/Hondo boundary correctly:

```bash
npm run build:ui
zig build test-integration -Doptimize=ReleaseSafe
```

This layer covers native views, leader actions, Ex/public commands, popup state, Lua configuration, completion UI, and renderer/state synchronization. Ex entry is explicitly regression-tested while the project tree owns keyboard input: `:` is routed directly through the Zig editor grammar, its command-line state is published to Hondo, and Escape returns to the still-open tree.

### 4. Real PTY end-to-end test

The terminal equivalent of a browser E2E test:

```bash
npm run build:ui
zig build -Doptimize=ReleaseSafe
python scripts/interactive_smoke.py ./zig-out/bin/zim
```

The PTY test launches the real ReleaseSafe binary in a deterministic terminal and exercises the user-visible workflow that headless tests cannot prove: dashboard rendering, `<Space>e`, explorer toggle and collapse/expand, nested file opening, visible Ex mode from tree focus, `:checkhealth`, representative Vim motions/operators/counts, Ctrl jump routing, writes, and `:q!`.

### 5. Release/platform smoke

CI builds and exercises ReleaseSafe Zim on Linux, macOS, and Windows. It includes Windows PTY/ConPTY lifecycle coverage, real ZLS smoke on Linux, release packaging dry runs, performance budgets, MessagePack-RPC process-boundary tests, Hondo integration, and the complete ReleaseSafe Zig suite.

## CI rule

A v1 candidate is not valid because one layer is green. The exact candidate SHA must pass the complete matrix, and human real-project dogfooding remains the final usability gate before merge/tag.

Playwright should only be introduced if Zim gains a real browser-rendered surface that users actually run. It should not replace PTY testing for the terminal application.
