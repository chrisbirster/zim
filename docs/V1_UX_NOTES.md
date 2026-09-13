# v1 UX blocker notes

During first real Apple Terminal dogfooding, Zim successfully launched after the QuickJS startup fix but the interactive shell still felt like an internal workspace prototype rather than a primary editor. The dogfood reference established the release target: a Zim-branded Neovim-style dashboard, Space-leader project explorer and Pins/Harpoon workflow, centered Zen editing, native file rendering, and reliable Ex quit commands.

A later dogfood pass exposed a deeper compatibility gap: several Vim behaviors existed in the headless core but did not survive the real TUI focus path after project-tree navigation. v1 therefore now requires interactive parity for Ex mode, representative multi-key motions/operators, and a hierarchical project tree with explicit expand/collapse behavior. These requirements are tracked by issues #45 and #46.

This document is intentionally short; the normative requirements live in `V1_UX_ACCEPTANCE.md` and the executable human checklist lives in `V1_UX_DOGFOOD.md`.
