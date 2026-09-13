#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing anchor: {label}")
    return text.replace(old, new, 1)

# TUI owns tree keyboard routing instead of relying on one-shot JS focus.
p = Path('src/tui.zig')
s = p.read_text()
s = replace_once(s,
'''    leader: default_leader.State = .{},
    pending_ui_action: ?UiAction = null,
''',
'''    leader: default_leader.State = .{},
    pending_ui_action: ?UiAction = null,
    tree_open: bool = false,
''', 'tree state')

s = replace_once(s,
'''    fn dispatch(self: *TuiApp, incoming: hondo.terminal.input.Event) !hondo.native_view_runtime.DispatchResult {
        try self.syncFocus();
        if (isExEntryEvent(incoming) and self.editor.mode == .normal) try self.focusEditor();
        const before_buffer_id = self.editor.currentBufferConst().id;
''',
'''    fn dispatch(self: *TuiApp, incoming: hondo.terminal.input.Event) !hondo.native_view_runtime.DispatchResult {
        try self.syncFocus();
        const ex_entry = isExEntryEvent(incoming) and self.editor.mode == .normal;
        if (ex_entry) {
            try self.focusEditor();
        } else if (self.tree_open and !self.editor.commandOpen()) {
            try self.focusTree();
        }
        const before_buffer_id = self.editor.currentBufferConst().id;
''', 'dispatch focus ownership')

s = replace_once(s,
'''        try self.applyPendingUiAction();
        if (before_buffer_id != self.editor.currentBufferConst().id or isEscapeEvent(incoming)) {
            try self.registry.sync(self.scene);
        }
        try self.syncFocus();
''',
'''        try self.applyPendingUiAction();
        if (before_buffer_id != self.editor.currentBufferConst().id) {
            self.tree_open = false;
            try self.runtime.eval(
                "globalThis.__zimCloseTree?.();",
                "zim-close-tree-after-open.js",
            );
            try self.registry.sync(self.scene);
            try self.syncFocus();
        } else if (isEscapeEvent(incoming)) {
            try self.registry.sync(self.scene);
        }
        try self.syncFocus();
''', 'post dispatch close')

s = replace_once(s,
'''    fn focusEditor(self: *TuiApp) !void {
        try self.runtime.eval(
            "globalThis.__zimFocusEditor?.();",
            "zim-focus-editor.js",
        );
        try self.registry.sync(self.scene);
        try self.syncFocus();
    }

    fn applyPendingUiAction''',
'''    fn focusEditor(self: *TuiApp) !void {
        try self.runtime.eval(
            "globalThis.__zimFocusEditor?.();",
            "zim-focus-editor.js",
        );
        try self.registry.sync(self.scene);
        try self.syncFocus();
    }

    fn focusTree(self: *TuiApp) !void {
        try self.runtime.eval(
            "globalThis.__zimFocusTree?.();",
            "zim-focus-tree.js",
        );
        try self.registry.sync(self.scene);
        try self.syncFocus();
    }

    fn applyPendingUiAction''', 'focus tree helper')

s = replace_once(s,
'''        switch (action) {
            .toggle_tree => try self.runtime.eval(
                "globalThis.__zimToggleTree?.();",
                "zim-toggle-tree.js",
            ),
            .toggle_zen => try self.runtime.eval(
''',
'''        switch (action) {
            .toggle_tree => {
                self.tree_open = !self.tree_open;
                try self.runtime.eval(
                    "globalThis.__zimToggleTree?.();",
                    "zim-toggle-tree.js",
                );
            },
            .toggle_zen => try self.runtime.eval(
''', 'toggle authoritative state')

s = replace_once(s,
'''    fn prepareKey(self: *TuiApp, key: hondo.terminal.input.Key) !?hondo.terminal.input.Key {
        if (key == .enter and self.editor.commandOpen()) {
''',
'''    fn prepareKey(self: *TuiApp, key: hondo.terminal.input.Key) !?hondo.terminal.input.Key {
        if (key == .escape and self.tree_open and !self.editor.commandOpen()) {
            self.leader.reset();
            self.pending_ui_action = .toggle_tree;
            return null;
        }

        if (key == .enter and self.editor.commandOpen()) {
''', 'escape tree close')
p.write_text(s)

# JS exposes explicit focus/close operations for Zig's ownership model.
p = Path('ui/src/bundle.ts')
s = p.read_text()
s = replace_once(s,
'''  __zimFocusEditor?: () => void;
  __zimToggleZen?: () => void;
''',
'''  __zimFocusEditor?: () => void;
  __zimFocusTree?: () => void;
  __zimCloseTree?: () => void;
  __zimToggleZen?: () => void;
''', 'global types')

s = replace_once(s,
'''globals.__zimFocusEditor = () => {
  setFocusZone('editor');
  flush();
  editorRef?.focus();
};

globals.__zimToggleZen = () => {
''',
'''globals.__zimFocusEditor = () => {
  setFocusZone('editor');
  flush();
  editorRef?.focus();
};

globals.__zimFocusTree = () => {
  if (!treeOpen()) return;
  setFocusZone('tree');
  flush();
  treeRef?.focus();
};

globals.__zimCloseTree = () => {
  if (treeOpen()) setTreeOpen(false);
  setFocusZone('editor');
  flush();
  editorRef?.focus();
};

globals.__zimToggleZen = () => {
''', 'global implementations')

s = replace_once(s,
'''  globals.__zimFocusEditor = undefined;
  globals.__zimToggleZen = undefined;
''',
'''  globals.__zimFocusEditor = undefined;
  globals.__zimFocusTree = undefined;
  globals.__zimCloseTree = undefined;
  globals.__zimToggleZen = undefined;
''', 'global cleanup')
p.write_text(s)
