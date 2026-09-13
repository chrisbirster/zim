# Development and release workflow

## Branches

Hondo uses an integration-branch workflow:

```text
feature/* -> dev -> main -> release
```

- `main` is always intended to be releasable.
- `dev` is the active integration branch.
- feature branches are created from the current `dev`.
- feature pull requests target `dev`.
- `dev` is periodically promoted to `main` after integration checks pass.
- releases are cut from `main` only.

Do not develop directly on `main`.

## Feature branches

Keep feature branches focused and short-lived. Before opening or merging a PR, incorporate current `dev` so the integration surface is known.

Initial train:

```text
feature/foundation
feature/universal-renderer
feature/terminal-engine
feature/styling-spike
```

Later milestone-specific branches should follow the same pattern, for example `feature/native-view` or `feature/components-input`.

## Integration cadence

There is no fixed calendar requirement. Merge feature work into `dev` whenever a coherent slice is complete and CI is green. Do not wait for an entire milestone if earlier slices are independently useful and compatible.

Promote `dev` to `main` when:

1. the intended milestone/release slice is complete,
2. all required cross-platform CI is green,
3. examples and public APIs used by the slice are coherent,
4. known breaking changes are documented,
5. the release notes can state a meaningful user-visible capability.

## Release policy

Hondo follows Semantic Versioning.

Pre-1.0 train:

```text
v0.1.0-alpha.1
v0.1.0-alpha.2
v0.1.0-alpha.3
v0.1.0-beta.1
v0.1.0-beta.2
v0.1.0-rc.1
v0.1.0
```

Release flow:

```text
feature branch
      |
      v
PR -> dev
      |
integration validation
      |
      v
PR dev -> main
      |
main CI
      |
      v
SemVer tag + GitHub Release
```

Every release should include:

- exact version/tag
- concise capability summary
- notable API changes
- compatibility notes
- known limitations
- verification/CI status

## Architecture invariants

- Hondo is terminal-native; no DOM, browser, WebView, or CSS engine is required at runtime.
- Hondo is independent from StingJS and Zim.
- Solid handles reactive application composition.
- Zig handles terminal lifecycle, input decoding, layout/paint infrastructure, cell grids, and terminal output.
- QuickJS runs Solid/Hondo application logic but is not the owner of performance-critical native application loops.
- application-specific heavyweight views can process input/render natively through `NativeView`.
- styling remains experimental until milestone M4 chooses a model.

## CI expectations

At minimum, pull requests and integration promotions should verify:

- Linux
- macOS
- Windows
- Zig formatting/build/tests
- TypeScript typecheck/tests/formatting
- example build(s)

The repository should stay buildable on `dev` and `main` throughout development.
