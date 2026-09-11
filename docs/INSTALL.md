# Install and Update Zim

Zim 1.0 release CI produces native ReleaseSafe archives for Linux, macOS and Windows.

## macOS / Linux

Install the latest release into `~/.local/bin`:

```sh
curl -fsSL https://raw.githubusercontent.com/chrisbirster/zim/main/scripts/install.sh | sh
```

Override the destination or version:

```sh
ZIM_INSTALL_DIR="$HOME/bin" ZIM_VERSION=1.0.0 sh scripts/install.sh
```

Supported release architectures are `x86_64` and `aarch64` when a matching GitHub release asset exists.

## Windows PowerShell

```powershell
irm https://raw.githubusercontent.com/chrisbirster/zim/main/scripts/install.ps1 | iex
```

By default Zim installs to `%LOCALAPPDATA%\Zim\bin`. Override with `ZIM_INSTALL_DIR` or pin a release with `ZIM_VERSION`.

## Verify

```text
zim --version
zim --check
```

`--version` reports the product and public extension versions. `--check` also reports terminal family, color availability and SSH/tmux context.

## Update

Re-running the installer replaces only the Zim executable in the selected install directory. User configuration, plugins, sessions, recovery data and Pins live in the platform config root and are not removed by an executable update.

Before a major-version update, review the compatibility notes. Zim 1.x keeps public API/plugin/RPC version 1 compatible according to `docs/API_STABILITY.md`.

## Build from source

Requirements:

- Zig 0.16.0
- Node.js 22 for the Solid/Hondo UI bundle

```sh
npm install --no-audit --no-fund
npm run build:ui
zig build -Doptimize=ReleaseSafe
./zig-out/bin/zim --check
```
