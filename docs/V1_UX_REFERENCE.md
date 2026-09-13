# v1 interactive reference

The intended v1 interaction model is deliberately familiar to Neovim users while keeping Zim's own identity and native Zig editor core.

| Action | Default |
| --- | --- |
| Leader | Space |
| Explorer | `<leader>e` |
| Add pin | `<leader>a` |
| Pins / Harpoon | `<leader>h` |
| Zen toggle | `<leader>z` |
| Quit | `:q` |
| Force quit | `:q!` |
| Save + quit | `:wq` / `:x` |

The empty editor shows a Zim dashboard. The project explorer and Harpoon picker are transient surfaces, not permanent debug rails. Zen mode keeps the native editor centered. File editing keeps line numbers, Tree-sitter highlighting, diagnostics/extmarks, and modal behavior on the Zig path.
