# Zim v1 UX dogfood checklist

Use a ReleaseSafe build from `feature/v1.0-daily-driver`.

- [ ] `zim` opens the Zim dashboard with no stray popup.
- [ ] `:q` exits an unmodified session.
- [ ] `:q!` exits a modified session without writing.
- [ ] `:wq` writes and exits a file-backed buffer.
- [ ] `<Space>e` opens the project explorer rooted at the project/current working directory.
- [ ] `j`/`k` move in the explorer and Enter opens a file.
- [ ] Escape and `<Space>e` close the explorer and return focus to the editor.
- [ ] `<Space>z` toggles centered Zen/workspace chrome.
- [ ] Opening a Zig file shows native line numbers, syntax highlights, cursor line, status, diagnostics/extmarks when present.
- [ ] `<Space>a` pins the current file/location.
- [ ] `<Space>h` opens the `HARPOON` pin picker.
- [ ] `j`/`k`, Enter, Escape, and `1`-`9` work in the pin picker.
- [ ] Normal insert/navigation keystrokes remain responsive and do not route through JavaScript.
