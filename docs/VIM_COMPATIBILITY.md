# Vim Compatibility — Zim v1.0

Zim is not attempting to clone every historical Vim command in v1.0, but the modal editing surface advertised as Vim-compatible must behave consistently through the real terminal UI, not only in headless editor tests.

This matrix is the v1 release contract tracked by issues #42, #45, and #46. A row is not considered complete until its representative sequences pass both core tests and the interactive TUI path where terminal routing or focus can affect the result.

## Motion grammar

| Family | v1 sequences |
| --- | --- |
| Character / line | `h j k l`, arrows, `0 ^ $`, `+ - _ |` |
| Word | `w W b B e E ge gE` |
| Buffer / line | `gg`, `G`, `{count}G` |
| Find / till | `f F t T ; ,` |
| Structural text | `%`, `(` `)`, `{` `}` |
| Viewport | `H M L`, `Ctrl-b`, `Ctrl-f`, `Ctrl-d`, `Ctrl-u`, `Ctrl-e`, `Ctrl-y` |
| Search | `/ ? n N * #` |
| Marks / jumps | `m{char}`, `` `{char}``, `'{char}`, `Ctrl-o`, `Ctrl-i`, `g;`, `g,` |
| Counts | Numeric prefixes compose with supported motions and operator motions |

## Operators and editing

| Family | v1 sequences |
| --- | --- |
| Operators | `d c y` + supported motions |
| Doubled operators | `dd cc yy` |
| Character / line shortcuts | `x X s S C D Y` |
| Put | `p P` |
| History | `u`, `Ctrl-r`, `.` |
| Visual | `v`, `V`, `Ctrl-v` with core navigation and `d/c/y` |
| Text objects | `iw/aw`, quoted/bracketed objects, sentence/paragraph objects, plus Zim structural objects where available |
| Registers / macros | named/numbered/small-delete/black-hole registers and `q`/`@` macro workflow |

## Ex command line

The actual terminal UI must visibly render `:<text>` while entering Ex commands. `Backspace`, `Esc`, and `Enter` must work, and at minimum `:q`, `:q!`, `:w`, `:wq`, `:x`, `:e`, `:help`, and lowercase `:checkhealth` must be reachable regardless of the previous dashboard/tree focus state.

## Project explorer

`<Space>e` is a global toggle. The project tree is hierarchical, tracks expanded/collapsed directories, navigates only visible nodes with `j/k`, expands with `Enter`/right/`l`, collapses or selects the parent with left/`h`, and returns focus to the editor with `Esc` or `<Space>e`.

Tree input routing is owned by the Zig TUI while the explorer is open. Hondo focus remains a presentation concern rather than the correctness mechanism for `Enter`, `j/k`, `h/l`, and arrow-key behavior. Global commands such as `<Space>e` and `:` are intercepted before tree dispatch so they remain reachable from tree focus.

## Release PTY gate

The macOS ReleaseSafe CI binary is exercised through a real pseudoterminal. The gate starts from the no-file dashboard and verifies the user-visible path rather than merely calling `Editor.handleKey()`:

- dashboard renders `ZIM v1.0.0`, `:checkhealth`, `:help`, `:q`, and the project-explorer hint;
- lowercase `:checkhealth` executes from startup and its popup can be dismissed with `Esc`;
- `<Space>e` opens, closes from tree focus, and reopens the explorer;
- `:` visibly enters Ex command mode while the tree owns the keyboard, and `Esc` returns to tree interaction;
- `Enter` expands a directory, `h` collapses it, `l` re-expands it, and `j` + `Enter` opens a nested file;
- `1G`, counted `G`, `d2w`, `2dw`, `dd`, `ciw`, `dG`, `dgg`, `Ctrl-o`, and terminal Tab/`Ctrl-i` are checked by writing the resulting buffer to disk and comparing exact contents;
- visible Ex mode survives cancellation and `:q!` exits the real process cleanly.

## Validation rule

Headless `Editor.handleKey()` coverage is necessary but not sufficient. Release-blocking representative paths must pass the real PTY gate above on the exact candidate head, along with the normal three-platform CI matrix. Human sustained dogfooding remains the final usability gate and cannot be replaced by automation.
