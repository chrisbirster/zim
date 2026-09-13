# Zim 1.0 Daily Driver

v1.0 is the point where Zim stops proving editor architecture and starts proving day-to-day trustworthiness.

## Release checklist

Before calling a commit a Zim 1.0 release candidate, use that exact build for real work and confirm:

- [ ] open the Zim repository as the primary editor for a sustained work session
- [ ] edit/save multiple Zig files and navigate with normal modal grammar
- [ ] use splits/tabs and restart Zim; confirm the workspace restores correctly
- [ ] leave an unsaved buffer, terminate Zim abnormally, then validate `:RecoveryRestore`
- [ ] exercise ZLS hover/definition/references/rename/format/completion
- [ ] load at least one Lua configuration and one installed plugin
- [ ] intentionally trigger a Lua/plugin error and verify the editor stays alive
- [ ] run a build/test command through `zim.job` or the built-in job commands
- [ ] open an interactive `:terminal`, resize it, interrupt a process, leave and reattach
- [ ] use Pins across a restart
- [ ] exercise `:Help`, `:Checkhealth`, `:Errors`, `:Colorscheme` and a custom `:Highlight`
- [ ] run under at least one direct terminal and one tmux or SSH session
- [ ] run `zim --check` and review diagnostics
- [ ] run the startup/large-file benchmark gate

This checklist is intentionally experiential. CI can prove deterministic invariants, but it cannot honestly claim that a human used the editor as a daily driver for a sustained session.

## Escape hatches

If a v1 workflow is not yet dependable:

- `:Errors` shows recent recoverable runtime failures.
- `:Checkhealth` shows the current extension/recovery/runtime state.
- `:RecoveryWrite` forces a crash checkpoint.
- `:SessionSave` forces a clean workspace snapshot.
- `--headless` lets you validate core startup without the TUI.
- `--check` validates build/API/terminal context without entering the editor.

## Known limits at 1.0

- Remote plugins remain local-only; Zim does not expose a TCP RPC listener.
- Hosted CI cannot fully emulate every terminal emulator, SSH topology or multiplexer configuration.
- Recovery checkpoints happen at stable editing boundaries rather than performing a filesystem write for every insert-mode keystroke.
- The plugin/public/RPC API policy guarantees compatibility for documented v1 surfaces; explicitly experimental surfaces remain outside that guarantee.

## Release discipline

The candidate branch must pass the complete Ubuntu/macOS/Windows gate. The exact merged `main` commit must pass the same gate before the v1.0 tracking issue is closed. A tag/release should be created from that validated `main` commit, not from an earlier PR head.
