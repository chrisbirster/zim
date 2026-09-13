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

The actual terminal UI must visibly render `:<text>` while entering Ex commands. `Backspace`, `Esc`, and `Enter` must work, and at minimum `:q`, `:q!`, `:w`, `:wq`, `:x`, `:e`, `:help`, and `:checkhealth` must be reachable regardless of the previous dashboard/tree focus state.

## Project explorer

`<Space>e` is a global toggle. The project tree is hierarchical, tracks expanded/collapsed directories, navigates only visible nodes with `j/k`, expands with `Enter`/right/`l`, collapses or selects the parent with left/`h`, and returns focus to the editor with `Esc` or `<Space>e`.

## Validation rule

Headless `Editor.handleKey()` coverage is necessary but not sufficient. Release-blocking representative paths are exercised through a real PTY, including project-tree focus handoff, `gg`/`G`, a visible Ex prompt and `:q!`, and representative operator+motion sequences. Human dogfooding remains the final usability gate.
