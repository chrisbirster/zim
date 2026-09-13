# M2 cross-platform terminal validation

This slice extends the existing real-terminal smoke beyond Linux.

- Linux: POSIX PTY lifecycle, resize, focused input, incremental redraw, restoration.
- macOS: the same POSIX PTY harness and assertions.
- Windows: a native ConPTY-backed pseudo console through pinned `pywinpty 3.0.5`, with the same resize/input/incremental-redraw/restoration assertions.

The Windows harness explicitly requests the ConPTY backend rather than accepting a WinPTY fallback.
