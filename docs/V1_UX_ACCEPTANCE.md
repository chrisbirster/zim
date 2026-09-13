# Zim v1 UX acceptance

The v1 Daily Driver release is not complete until the default interactive experience behaves like a familiar Neovim-class editor rather than exposing internal workspace/debug chrome.

## Empty startup

Running `zim` with no file opens a Zim-branded dashboard in the editor area:

- ZIM logo and `ZIM v1.0`
- catch phrase: `your new code overlord.`
- concise helper commands
- no permanently-open project/context rails
- no empty plugin popup
- `:q`, `:q!`, `:wq`, and `:x` work from the normal editor command line

## Leader keys

The built-in leader is Space for the default configuration.

- `<leader>e` toggles the project explorer
- `<leader>a` pins the current file and exact cursor location
- `<leader>h` opens the Harpoon-style pin picker
- `<leader>z` toggles Zen/workspace chrome

Leader handling must remain on the native Zig input path; ordinary editing keystrokes must not be routed through JavaScript.

## Project explorer

`<leader>e` opens a file tree rooted at the project/current working directory. The tree supports at minimum:

- `j`/`k` or arrows to move
- Enter to open a file and return focus to the editor
- `r` to refresh
- Escape or `<leader>e` to close

## Zen editor

Zen is the default editing layout:

- editor centered with quiet side margins
- line numbers, current-line treatment, syntax highlighting, diagnostics/extmarks, and modal cursor remain native
- normal status line shows mode, project/path context, modified state, and line/column
- opening a file should look and feel like a focused Neovim editing buffer

## Pins / Harpoon

- `<leader>a` adds the current file/location to persistent Pins
- `<leader>h` opens the pin picker titled `HARPOON`
- picker supports `j`/`k`, Enter, Escape, and numeric quick jumps
- selecting a pin opens the target and restores its saved location

## Release gate

These behaviors are human-dogfood release gates in addition to automated Ubuntu/macOS/Windows ReleaseSafe CI. Screenshots from the original dogfood session are the visual reference for the intended interaction model.
