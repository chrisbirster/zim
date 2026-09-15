# Terminal Compatibility

Zim is permanently a terminal product. v1 therefore treats terminal behavior as a release surface rather than a best-effort detail.

## Supported Daily Driver targets

The release target matrix is:

| Platform | Primary terminals | Status expectation |
| --- | --- | --- |
| macOS | WezTerm, Kitty, Alacritty, Terminal.app | editing, mouse/focus, resize, color, terminal sessions |
| Linux | WezTerm, Kitty, Alacritty, xterm-compatible terminals | editing, mouse/focus, resize, color, PTY sessions |
| Windows | Windows Terminal | editing, resize, color, ConPTY sessions |
| Remote | SSH in an xterm/screen/tmux-compatible environment | core editing and terminal restore |
| Multiplexer | tmux/screen-compatible `$TERM` | core editing, resize and color |

`zim --check` reports the terminal family Zim can infer from `TERM`, `TERM_PROGRAM`, `WT_SESSION`, `TMUX`, `SSH_CONNECTION` and related environment variables. It does not transmit this information anywhere.

## CI coverage

The three-platform CI gate exercises:

- terminal input/render integration through Hondo
- POSIX PTY behavior on Unix-like systems
- Windows ConPTY platform, child, nonblocking and terminal-manager lifecycle tests
- resize/input/exit ownership in native Zim
- a pure compatibility classifier for Kitty/WezTerm/Alacritty/xterm/screen/tmux/dumb environments

Some real terminal-emulator behavior cannot be fully modeled inside hosted CI. Those cases are part of the v1 dogfood checklist.

## SSH/tmux expectations

Zim never assumes it owns the user's outer terminal process. Alternate-screen, input-feature and cursor state must be restored on normal exit and on recoverable failures. Under tmux or SSH, Zim follows the terminal capabilities visible inside that session rather than trying to bypass the multiplexer or remote shell.

## Reporting a terminal bug

Include:

```text
zim --version
zim --check
```

plus the terminal application/version and whether the session is local, SSH, tmux, screen, WSL or another compatibility layer.
