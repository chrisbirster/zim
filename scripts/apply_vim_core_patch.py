#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing patch anchor: {label}")
    return text.replace(old, new, 1)

# ----- workspace viewport metadata -----
p = Path("src/workspace.zig")
s = p.read_text()
s = replace_once(
    s,
    '''    preferred_column: ?usize = null,\n    scroll_line: usize = 0,\n''',
    '''    preferred_column: ?usize = null,\n    scroll_line: usize = 0,\n    viewport_height: usize = 24,\n''',
    "window viewport height",
)
p.write_text(s)

# ----- editor view: viewport plumbing and legacy control-byte translation -----
p = Path("src/editor_view.zig")
s = p.read_text()
s = replace_once(
    s,
    '''    const window = editor.windowById(window_id) orelse return;\n    const buffer = editor.bufferById(window.buffer_id) orelse return;\n    ensureCursorVisible(editor, window_id, bounds.height);\n''',
    '''    const window = editor.windowById(window_id) orelse return;\n    window.viewport_height = @max(@as(usize, 1), bounds.height);\n    const buffer = editor.bufferById(window.buffer_id) orelse return;\n    ensureCursorVisible(editor, window_id, bounds.height);\n''',
    "paint viewport height",
)
old_translate = '''fn translateKey(key: hondo.terminal.input.Key) ?editor_module.Key {\n    return switch (key) {\n        .codepoint => |cp| .{ .codepoint = cp },\n        .enter => .enter,\n        .backspace => .backspace,\n        .tab => .tab,\n        .shift_tab => .shift_tab,\n        .escape => .escape,\n        .ctrl_c => .ctrl_c,\n        .up => .up,\n        .down => .down,\n        .left => .left,\n        .right => .right,\n    };\n}\n'''
new_translate = '''fn translateKey(key: hondo.terminal.input.Key) ?editor_module.Key {\n    return switch (key) {\n        // The currently pinned Hondo decoder exposes Ctrl-C explicitly and\n        // preserves the other legacy C0 control bytes as codepoints. Translate\n        // those bytes here so interactive Vim controls reach the same grammar as\n        // headless Editor.handleKey tests.\n        .codepoint => |cp| switch (cp) {\n            0x02 => .ctrl_b,\n            0x04 => .ctrl_d,\n            0x05 => .ctrl_e,\n            0x06 => .ctrl_f,\n            0x0b => .ctrl_k,\n            0x0c => .ctrl_l,\n            0x0f => .ctrl_o,\n            0x12 => .ctrl_r,\n            0x15 => .ctrl_u,\n            0x16 => .ctrl_v,\n            0x19 => .ctrl_y,\n            else => .{ .codepoint = cp },\n        },\n        .enter => .enter,\n        .backspace => .backspace,\n        .tab => .tab,\n        .shift_tab => .shift_tab,\n        .escape => .escape,\n        .ctrl_c => .ctrl_c,\n        .up => .up,\n        .down => .down,\n        .left => .left,\n        .right => .right,\n    };\n}\n'''
s = replace_once(s, old_translate, new_translate, "control translation")
p.write_text(s)

# ----- UI bridge: explicit editor focus request -----
p = Path("ui/src/bundle.ts")
s = p.read_text()
s = replace_once(
    s,
    '''  __zimToggleTree?: () => void;\n  __zimToggleZen?: () => void;\n''',
    '''  __zimToggleTree?: () => void;\n  __zimToggleZen?: () => void;\n  __zimFocusEditor?: () => void;\n''',
    "focus global type",
)
s = replace_once(
    s,
    '''globals.__zimToggleZen = () => {\n''',
    '''globals.__zimFocusEditor = () => {\n  setFocusZone('editor');\n  flush();\n  editorRef?.focus();\n};\n\nglobals.__zimToggleZen = () => {\n''',
    "focus global implementation",
)
s = replace_once(
    s,
    '''  globals.__zimToggleTree = undefined;\n  globals.__zimToggleZen = undefined;\n''',
    '''  globals.__zimToggleTree = undefined;\n  globals.__zimToggleZen = undefined;\n  globals.__zimFocusEditor = undefined;\n''',
    "focus global cleanup",
)
p.write_text(s)

# ----- TUI focus ownership and q/q! test-state fix -----
p = Path("src/tui.zig")
s = p.read_text()
s = replace_once(
    s,
    '''    fn dispatch(self: *TuiApp, incoming: hondo.terminal.input.Event) !hondo.native_view_runtime.DispatchResult {\n        try self.syncFocus();\n        const before = api_observer.capture(self.editor);\n''',
    '''    fn dispatch(self: *TuiApp, incoming: hondo.terminal.input.Event) !hondo.native_view_runtime.DispatchResult {\n        try self.syncFocus();\n        if (isExEntryEvent(incoming) and self.editor.mode == .normal) try self.focusEditor();\n        const before_buffer_id = self.editor.currentBufferConst().id;\n        const before = api_observer.capture(self.editor);\n''',
    "dispatch pre-focus",
)
s = replace_once(
    s,
    '''        try self.applyPendingUiAction();\n        try self.syncFocus();\n        try api_observer.emitChanges(self.api, self.editor, before);\n        return result;\n    }\n\n    fn applyPendingUiAction''',
    '''        try self.applyPendingUiAction();\n        if (before_buffer_id != self.editor.currentBufferConst().id or isEscapeEvent(incoming)) {\n            try self.registry.sync(self.scene);\n        }\n        try self.syncFocus();\n        try api_observer.emitChanges(self.api, self.editor, before);\n        return result;\n    }\n\n    fn focusEditor(self: *TuiApp) !void {\n        try self.runtime.eval(\n            "globalThis.__zimFocusEditor?.();",\n            "zim-focus-editor.js",\n        );\n        try self.registry.sync(self.scene);\n        try self.syncFocus();\n    }\n\n    fn applyPendingUiAction''',
    "dispatch post-focus",
)
s = replace_once(
    s,
    '''fn isImmediateQuitEvent(event: hondo.terminal.input.Event) bool {\n''',
    '''fn isExEntryEvent(event: hondo.terminal.input.Event) bool {\n    return switch (event) {\n        .key => |key| switch (key) {\n            .codepoint => |cp| cp == ':',\n            else => false,\n        },\n        else => false,\n    };\n}\n\nfn isEscapeEvent(event: hondo.terminal.input.Event) bool {\n    return switch (event) {\n        .key => |key| key == .escape,\n        else => false,\n    };\n}\n\nfn isImmediateQuitEvent(event: hondo.terminal.input.Event) bool {\n''',
    "event helpers",
)
s = replace_once(
    s,
    '''    editor.quit_requested = false;\n    try editor.setText("modified");\n''',
    '''    editor.quit_requested = false;\n    editor.mode = .normal;\n    try editor.setText("modified");\n''',
    "q test reset",
)
p.write_text(s)

# ----- editor core Vim motion/operator tranche -----
p = Path("src/editor.zig")
s = p.read_text()
s = replace_once(
    s,
    '''    ctrl_c,\n    ctrl_r,\n    ctrl_v,\n    ctrl_o,\n    ctrl_i,\n    ctrl_h,\n    ctrl_j,\n    ctrl_k,\n    ctrl_l,\n    ctrl_u,\n    ctrl_d,\n''',
    '''    ctrl_b,\n    ctrl_c,\n    ctrl_d,\n    ctrl_e,\n    ctrl_f,\n    ctrl_h,\n    ctrl_i,\n    ctrl_j,\n    ctrl_k,\n    ctrl_l,\n    ctrl_o,\n    ctrl_r,\n    ctrl_u,\n    ctrl_v,\n    ctrl_y,\n''',
    "Editor.Key controls",
)

old_controls = '''        return switch (key) {\n            .escape => blk: {\n                self.resetPending();\n                break :blk true;\n            },\n            .left => self.repeatMotion(.left, self.takeCount()),\n            .right => self.repeatMotion(.right, self.takeCount()),\n            .up => self.repeatMotion(.up, self.takeCount()),\n            .down => self.repeatMotion(.down, self.takeCount()),\n            .ctrl_r => try self.redo(),\n            .ctrl_o => blk: {\n                _ = self.jumpListMove(-1);\n                break :blk true;\n            },\n            .ctrl_i => blk: {\n                _ = self.jumpListMove(1);\n                break :blk true;\n            },\n            .ctrl_v => blk: {\n                self.enterVisual(.visual_block);\n                break :blk true;\n            },\n            .ctrl_u => blk: {\n                self.pageMove(-1);\n                break :blk true;\n            },\n            .ctrl_d => blk: {\n                self.pageMove(1);\n                break :blk true;\n            },\n            .ctrl_h => blk: {\n                self.previousWindow();\n                break :blk true;\n            },\n            .ctrl_l => blk: {\n                self.nextWindow();\n                break :blk true;\n            },\n'''
new_controls = '''        return switch (key) {\n            .escape => blk: {\n                self.resetPending();\n                break :blk true;\n            },\n            .enter => blk: {\n                self.moveRelativeFirstNonBlank(1, self.takeCount());\n                break :blk true;\n            },\n            .backspace => self.repeatMotion(.left, self.takeCount()),\n            .left => self.repeatMotion(.left, self.takeCount()),\n            .right => self.repeatMotion(.right, self.takeCount()),\n            .up => self.repeatMotion(.up, self.takeCount()),\n            .down => self.repeatMotion(.down, self.takeCount()),\n            .ctrl_r => try self.redo(),\n            .ctrl_o => blk: {\n                _ = self.jumpListMove(-1);\n                break :blk true;\n            },\n            .ctrl_i => blk: {\n                _ = self.jumpListMove(1);\n                break :blk true;\n            },\n            .ctrl_v => blk: {\n                self.enterVisual(.visual_block);\n                break :blk true;\n            },\n            .ctrl_u => blk: {\n                self.pageMove(-1, false, self.takeCount());\n                break :blk true;\n            },\n            .ctrl_d => blk: {\n                self.pageMove(1, false, self.takeCount());\n                break :blk true;\n            },\n            .ctrl_b => blk: {\n                self.pageMove(-1, true, self.takeCount());\n                break :blk true;\n            },\n            .ctrl_f => blk: {\n                self.pageMove(1, true, self.takeCount());\n                break :blk true;\n            },\n            .ctrl_e => blk: {\n                self.scrollViewport(1, self.takeCount());\n                break :blk true;\n            },\n            .ctrl_y => blk: {\n                self.scrollViewport(-1, self.takeCount());\n                break :blk true;\n            },\n            .ctrl_h => blk: {\n                self.previousWindow();\n                break :blk true;\n            },\n            .ctrl_l => blk: {\n                self.nextWindow();\n                break :blk true;\n            },\n'''
s = replace_once(s, old_controls, new_controls, "normal control motions")

s = replace_once(
    s,
    '''            if (cp == 'p') return self.openPinSwitcher();\n            if (cp == ';') return self.changeListMove(-1);\n            if (cp == ',') return self.changeListMove(1);\n''',
    '''            if (cp == 'e' or cp == 'E') {\n                const ge_count = self.takeCount();\n                for (0..ge_count) |_| {\n                    self.currentWindow().cursor = if (cp == 'E')\n                        previousWORDend(self.text(), self.cursor())\n                    else\n                        previousWordEnd(self.text(), self.cursor());\n                }\n                return true;\n            }\n            if (cp == 'p') return self.openPinSwitcher();\n            if (cp == ';') return self.changeListMove(-1);\n            if (cp == ',') return self.changeListMove(1);\n''',
    "normal ge gE",
)

s = replace_once(
    s,
    '''            'w' => blk: {\n                for (0..count) |_| self.moveWordForward();\n                break :blk true;\n            },\n            'b' => blk: {\n                for (0..count) |_| self.moveWordBackward();\n                break :blk true;\n            },\n            'e' => blk: {\n                for (0..count) |_| self.moveWordEnd();\n                break :blk true;\n            },\n''',
    '''            'w' => blk: {\n                for (0..count) |_| self.moveWordForward();\n                break :blk true;\n            },\n            'W' => blk: {\n                for (0..count) |_| self.moveWORDForward();\n                break :blk true;\n            },\n            'b' => blk: {\n                for (0..count) |_| self.moveWordBackward();\n                break :blk true;\n            },\n            'B' => blk: {\n                for (0..count) |_| self.moveWORDBackward();\n                break :blk true;\n            },\n            'e' => blk: {\n                for (0..count) |_| self.moveWordEnd();\n                break :blk true;\n            },\n            'E' => blk: {\n                for (0..count) |_| self.moveWORDEnd();\n                break :blk true;\n            },\n''',
    "WORD motions",
)

s = replace_once(
    s,
    '''            'G' => blk: {\n                if (count > 1) self.moveToLine(count - 1) else self.currentWindow().cursor = self.text().len;\n                break :blk true;\n            },\n''',
    '''            'G' => blk: {\n                if (count > 1) self.moveToLine(count - 1) else self.moveToLastLine();\n                break :blk true;\n            },\n            'H' => blk: {\n                self.moveViewport(.top, count);\n                break :blk true;\n            },\n            'M' => blk: {\n                self.moveViewport(.middle, count);\n                break :blk true;\n            },\n            'L' => blk: {\n                self.moveViewport(.bottom, count);\n                break :blk true;\n            },\n            '+' => blk: {\n                self.moveRelativeFirstNonBlank(1, count);\n                break :blk true;\n            },\n            '-' => blk: {\n                self.moveRelativeFirstNonBlank(-1, count);\n                break :blk true;\n            },\n            '_' => blk: {\n                self.moveRelativeFirstNonBlank(1, count - 1);\n                break :blk true;\n            },\n            '|' => blk: {\n                self.moveToColumn(count - 1);\n                break :blk true;\n            },\n            '*' => blk: {\n                _ = try self.searchWordUnderCursor(true);\n                break :blk true;\n            },\n            '#' => blk: {\n                _ = try self.searchWordUnderCursor(false);\n                break :blk true;\n            },\n''',
    "viewport and line motions",
)

s = replace_once(
    s,
    '''            'x' => blk: {\n                try self.beginChange(key);\n                for (0..count) |_| if (!(try self.deleteCharacter())) break;\n                self.finishUndoGroup();\n                try self.finishChange();\n                break :blk true;\n            },\n''',
    '''            'x' => blk: {\n                try self.beginChange(key);\n                for (0..count) |_| if (!(try self.deleteCharacter())) break;\n                self.finishUndoGroup();\n                try self.finishChange();\n                break :blk true;\n            },\n            'X' => blk: {\n                try self.beginChange(key);\n                for (0..count) |_| if (!(try self.deleteCharacterBackward())) break;\n                self.finishUndoGroup();\n                try self.finishChange();\n                break :blk true;\n            },\n            's' => blk: {\n                try self.beginChange(key);\n                for (0..count) |_| if (!(try self.deleteCharacter())) break;\n                self.mode = .insert;\n                break :blk true;\n            },\n            'S' => blk: {\n                try self.beginChange(key);\n                try self.applyOperator(.change, self.lineRange(self.cursor(), count));\n                break :blk true;\n            },\n            'C' => blk: {\n                try self.beginChange(key);\n                const range = self.motionRange('$', 1) orelse self.lineRange(self.cursor(), 1);\n                try self.applyOperator(.change, range);\n                break :blk true;\n            },\n            'D' => blk: {\n                try self.beginChange(key);\n                const range = self.motionRange('$', 1) orelse self.lineRange(self.cursor(), 1);\n                try self.applyOperator(.delete, range);\n                break :blk true;\n            },\n            'Y' => blk: {\n                try self.applyOperator(.yank, self.lineRange(self.cursor(), count));\n                break :blk true;\n            },\n''',
    "normal editing shortcuts",
)

# Visual mode parity for common motions.
s = replace_once(
    s,
    '''                    'w' => self.moveWordForward(),\n                    'b' => self.moveWordBackward(),\n                    'e' => self.moveWordEnd(),\n                    '0' => self.currentWindow().cursor = lineStartAt(self.text(), self.cursor()),\n                    '$' => self.currentWindow().cursor = lineEnd(self.text(), self.cursor()),\n''',
    '''                    'w' => self.moveWordForward(),\n                    'W' => self.moveWORDForward(),\n                    'b' => self.moveWordBackward(),\n                    'B' => self.moveWORDBackward(),\n                    'e' => self.moveWordEnd(),\n                    'E' => self.moveWORDEnd(),\n                    '0' => self.currentWindow().cursor = lineStartAt(self.text(), self.cursor()),\n                    '^' => self.currentWindow().cursor = firstNonBlank(self.text(), lineStartAt(self.text(), self.cursor())),\n                    '$' => self.currentWindow().cursor = lineEnd(self.text(), self.cursor()),\n                    'G' => self.moveToLastLine(),\n                    'g' => self.pending_g = true,\n''',
    "visual word motions",
)
# Add visual pending-gg handling before return switch.
s = replace_once(
    s,
    '''    fn handleVisual(self: *Editor, key: Key) !bool {\n        return switch (key) {\n''',
    '''    fn handleVisual(self: *Editor, key: Key) !bool {\n        if (self.pending_g) {\n            self.pending_g = false;\n            if (key == .codepoint and key.codepoint == 'g') {\n                self.moveToLine(0);\n                return true;\n            }\n        }\n        return switch (key) {\n''',
    "visual gg",
)

# Operator-pending g{e,E} and uppercase WORD motions.
s = replace_once(
    s,
    '''            .codepoint => |cp| blk: {\n                if (cp >= '1' and cp <= '9') {\n''',
    '''            .codepoint => |cp| blk: {\n                if (self.pending_g) {\n                    self.pending_g = false;\n                    if (cp == 'e' or cp == 'E') {\n                        const motion_count = self.operator_count * self.takeCount();\n                        const range = self.previousEndMotionRange(cp == 'E', motion_count);\n                        try self.applyOperator(op, range);\n                        break :blk true;\n                    }\n                    self.resetOperator();\n                    break :blk false;\n                }\n                if (cp >= '1' and cp <= '9') {\n''',
    "operator pending g",
)
s = replace_once(
    s,
    '''                if (cp == 'i' or cp == 'a') {\n                    self.pending_text_object = if (cp == 'i') .inner else .around;\n                    break :blk true;\n                }\n''',
    '''                if (cp == 'i' or cp == 'a') {\n                    self.pending_text_object = if (cp == 'i') .inner else .around;\n                    break :blk true;\n                }\n                if (cp == 'g') {\n                    self.pending_g = true;\n                    break :blk true;\n                }\n''',
    "operator g prefix",
)

# Motion range WORD and viewport/line motions.
s = replace_once(
    s,
    '''            'w' => {\n                for (0..count) |_| target = nextWordStart(self.text(), target);\n            },\n            'b' => {\n                for (0..count) |_| target = previousWordStart(self.text(), target);\n            },\n            'e' => {\n                for (0..count) |_| target = wordEndOffset(self.text(), target);\n                inclusive = true;\n            },\n''',
    '''            'w' => {\n                for (0..count) |_| target = nextWordStart(self.text(), target);\n            },\n            'W' => {\n                for (0..count) |_| target = nextWORDStart(self.text(), target);\n            },\n            'b' => {\n                for (0..count) |_| target = previousWordStart(self.text(), target);\n            },\n            'B' => {\n                for (0..count) |_| target = previousWORDStart(self.text(), target);\n            },\n            'e' => {\n                for (0..count) |_| target = wordEndOffset(self.text(), target);\n                inclusive = true;\n            },\n            'E' => {\n                for (0..count) |_| target = WORDEndOffset(self.text(), target);\n                inclusive = true;\n            },\n''',
    "operator WORD motion ranges",
)
s = replace_once(
    s,
    '''            '$' => {\n                target = lineEnd(self.text(), start);\n                inclusive = false;\n            },\n            '%' => target = matchingDelimiterOffset(self.text(), start) orelse return null,\n''',
    '''            '$' => {\n                target = lineEnd(self.text(), start);\n                inclusive = false;\n            },\n            '+', '-', '_' => {\n                const current_line = self.cursorPosition().line - 1;\n                const target_line = if (cp == '-')\n                    current_line -| count\n                else if (cp == '_')\n                    current_line +| (count - 1)\n                else\n                    current_line +| count;\n                const line_start = offsetForLineColumn(self.text(), target_line, 0);\n                target = firstNonBlank(self.text(), line_start);\n            },\n            '|' => {\n                target = offsetForLineCodepointColumn(self.text(), self.cursorPosition().line - 1, count - 1);\n            },\n            'H', 'M', 'L' => target = self.viewportTargetOffset(cp, count),\n            '%' => target = matchingDelimiterOffset(self.text(), start) orelse return null,\n''',
    "operator line/viewport ranges",
)

# Movement helper methods in Editor.
s = replace_once(
    s,
    '''    fn moveWordBackward(self: *Editor) void {\n        self.currentWindow().cursor = previousWordStart(self.text(), self.cursor());\n    }\n\n    fn moveWordEnd(self: *Editor) void {\n        self.currentWindow().cursor = wordEndOffset(self.text(), self.cursor());\n    }\n\n    fn moveToLine(self: *Editor, line_index: usize) void {\n        self.currentWindow().cursor = offsetForLineColumn(self.text(), line_index, 0);\n    }\n\n    fn pageMove(self: *Editor, direction: i8) void {\n        for (0..10) |_| {\n            if (direction < 0) {\n                if (!self.moveUp()) break;\n            } else if (!self.moveDown()) break;\n        }\n    }\n''',
    '''    fn moveWordBackward(self: *Editor) void {\n        self.currentWindow().cursor = previousWordStart(self.text(), self.cursor());\n    }\n\n    fn moveWordEnd(self: *Editor) void {\n        self.currentWindow().cursor = wordEndOffset(self.text(), self.cursor());\n    }\n\n    fn moveWORDForward(self: *Editor) void {\n        self.currentWindow().cursor = nextWORDStart(self.text(), self.cursor());\n    }\n\n    fn moveWORDBackward(self: *Editor) void {\n        self.currentWindow().cursor = previousWORDStart(self.text(), self.cursor());\n    }\n\n    fn moveWORDEnd(self: *Editor) void {\n        self.currentWindow().cursor = WORDEndOffset(self.text(), self.cursor());\n    }\n\n    fn moveToLine(self: *Editor, line_index: usize) void {\n        self.currentWindow().cursor = offsetForLineColumn(self.text(), line_index, 0);\n    }\n\n    fn moveToLastLine(self: *Editor) void {\n        const bytes = self.text();\n        if (bytes.len == 0) {\n            self.currentWindow().cursor = 0;\n            return;\n        }\n        var probe = bytes.len;\n        if (probe > 0 and bytes[probe - 1] == '\\n') probe -= 1;\n        const start = lineStartAt(bytes, probe);\n        self.currentWindow().cursor = firstNonBlank(bytes, start);\n    }\n\n    const ViewportTarget = enum { top, middle, bottom };\n\n    fn viewportTargetOffset(self: *const Editor, cp: u21, count: usize) usize {\n        const window = self.currentWindowConst();\n        const height = @max(@as(usize, 1), window.viewport_height);\n        const line = switch (cp) {\n            'H' => window.scroll_line +| (count - 1),\n            'M' => window.scroll_line +| (height / 2),\n            'L' => window.scroll_line +| (height -| count),\n            else => window.scroll_line,\n        };\n        const start = offsetForLineColumn(self.text(), line, 0);\n        return firstNonBlank(self.text(), start);\n    }\n\n    fn moveViewport(self: *Editor, target: ViewportTarget, count: usize) void {\n        const cp: u21 = switch (target) { .top => 'H', .middle => 'M', .bottom => 'L' };\n        self.currentWindow().cursor = self.viewportTargetOffset(cp, count);\n    }\n\n    fn moveRelativeFirstNonBlank(self: *Editor, direction: i8, count: usize) void {\n        const current_line = self.cursorPosition().line - 1;\n        const line = if (direction < 0) current_line -| count else current_line +| count;\n        const start = offsetForLineColumn(self.text(), line, 0);\n        self.currentWindow().cursor = firstNonBlank(self.text(), start);\n    }\n\n    fn moveToColumn(self: *Editor, zero_based_column: usize) void {\n        self.currentWindow().cursor = offsetForLineCodepointColumn(\n            self.text(),\n            self.cursorPosition().line - 1,\n            zero_based_column,\n        );\n    }\n\n    fn pageMove(self: *Editor, direction: i8, full_page: bool, count: usize) void {\n        const height = @max(@as(usize, 1), self.currentWindowConst().viewport_height);\n        const amount = (if (full_page) height else @max(@as(usize, 1), height / 2)) * count;\n        for (0..amount) |_| {\n            if (direction < 0) {\n                if (!self.moveUp()) break;\n            } else if (!self.moveDown()) break;\n        }\n    }\n\n    fn scrollViewport(self: *Editor, direction: i8, count: usize) void {\n        const cursor_line = self.cursorPosition().line - 1;\n        const height = @max(@as(usize, 1), self.currentWindowConst().viewport_height);\n        if (direction < 0) {\n            self.currentWindow().scroll_line -|= count;\n            const bottom = self.currentWindowConst().scroll_line + height - 1;\n            if (cursor_line > bottom) self.moveToLine(bottom);\n        } else {\n            self.currentWindow().scroll_line += count;\n            if (cursor_line < self.currentWindowConst().scroll_line) self.moveToLine(self.currentWindowConst().scroll_line);\n        }\n    }\n\n    fn previousEndMotionRange(self: *Editor, big_word: bool, count: usize) Range {\n        const start = self.cursor();\n        var target = start;\n        for (0..count) |_| {\n            target = if (big_word) previousWORDend(self.text(), target) else previousWordEnd(self.text(), target);\n        }\n        const a = @min(start, target);\n        var b = @max(start, target);\n        if (b < self.text().len) b = nextCodepointStart(self.text(), b);\n        return .{ .start = a, .end = b };\n    }\n\n    fn searchWordUnderCursor(self: *Editor, forward: bool) !bool {\n        const range = wordUnderCursor(self.text(), self.cursor()) orelse return false;\n        self.search_pattern.items.len = 0;\n        try self.search_pattern.appendSlice(self.allocator, self.text()[range.start..range.end]);\n        return self.search(forward);\n    }\n''',
    "movement helpers",
)

# Backward delete helper.
s = replace_once(
    s,
    '''    fn deleteCharacter(self: *Editor) !bool {\n        if (self.cursor() >= self.text().len) return false;\n        const end = nextCodepointStart(self.text(), self.cursor());\n        try self.deleteRange(.{ .start = self.cursor(), .end = end });\n        return true;\n    }\n''',
    '''    fn deleteCharacter(self: *Editor) !bool {\n        if (self.cursor() >= self.text().len) return false;\n        const end = nextCodepointStart(self.text(), self.cursor());\n        try self.deleteRange(.{ .start = self.cursor(), .end = end });\n        return true;\n    }\n\n    fn deleteCharacterBackward(self: *Editor) !bool {\n        const cursor = self.cursor();\n        if (cursor == 0 or cursor == lineStartAt(self.text(), cursor)) return false;\n        const start = previousCodepointStartSafe(self.text(), cursor);\n        try self.deleteRange(.{ .start = start, .end = cursor });\n        return true;\n    }\n''',
    "backward delete",
)

# Ensure operator reset clears g prefix.
s = replace_once(
    s,
    '''        self.pending_text_object = null;\n        self.operator_count = 1;\n''',
    '''        self.pending_text_object = null;\n        self.pending_g = false;\n        self.operator_count = 1;\n''',
    "operator g reset",
)

# WORD/previous-end helpers near existing word helpers.
anchor = '''fn letterIndex(cp: u21) ?usize {\n'''
helpers = r'''fn nextWORDStart(bytes: []const u8, cursor: usize) usize {
    var index = @min(cursor, bytes.len);
    if (index < bytes.len and !isSpaceByte(bytes[index])) {
        while (index < bytes.len and !isSpaceByte(bytes[index])) index = nextCodepointStart(bytes, index);
    }
    while (index < bytes.len and isSpaceByte(bytes[index])) index = nextCodepointStart(bytes, index);
    return index;
}

fn previousWORDStart(bytes: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var index = previousCodepointStartSafe(bytes, cursor);
    while (index > 0 and isSpaceByte(bytes[index])) index = previousCodepointStartSafe(bytes, index);
    while (index > 0) {
        const previous = previousCodepointStartSafe(bytes, index);
        if (isSpaceByte(bytes[previous])) break;
        index = previous;
    }
    return index;
}

fn WORDEndOffset(bytes: []const u8, cursor: usize) usize {
    var index = @min(cursor, bytes.len);
    if (index >= bytes.len) return bytes.len;
    if (!isSpaceByte(bytes[index])) {
        const next = nextCodepointStart(bytes, index);
        if (next < bytes.len and !isSpaceByte(bytes[next])) {
            var last = index;
            var scan = index;
            while (scan < bytes.len and !isSpaceByte(bytes[scan])) {
                last = scan;
                scan = nextCodepointStart(bytes, scan);
            }
            return last;
        }
        index = next;
    }
    while (index < bytes.len and isSpaceByte(bytes[index])) index = nextCodepointStart(bytes, index);
    if (index >= bytes.len) return bytes.len;
    var last = index;
    while (index < bytes.len and !isSpaceByte(bytes[index])) {
        last = index;
        index = nextCodepointStart(bytes, index);
    }
    return last;
}

fn previousWordEnd(bytes: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var index = previousCodepointStartSafe(bytes, cursor);
    if (!isSpaceByte(bytes[index])) {
        const class = isWordByte(bytes[index]);
        var start = index;
        while (start > 0) {
            const previous = previousCodepointStartSafe(bytes, start);
            if (isSpaceByte(bytes[previous]) or isWordByte(bytes[previous]) != class) break;
            start = previous;
        }
        if (start == 0) return 0;
        index = previousCodepointStartSafe(bytes, start);
    }
    while (index > 0 and isSpaceByte(bytes[index])) index = previousCodepointStartSafe(bytes, index);
    return index;
}

fn previousWORDend(bytes: []const u8, cursor: usize) usize {
    if (cursor == 0) return 0;
    var index = previousCodepointStartSafe(bytes, cursor);
    if (!isSpaceByte(bytes[index])) {
        var start = index;
        while (start > 0) {
            const previous = previousCodepointStartSafe(bytes, start);
            if (isSpaceByte(bytes[previous])) break;
            start = previous;
        }
        if (start == 0) return 0;
        index = previousCodepointStartSafe(bytes, start);
    }
    while (index > 0 and isSpaceByte(bytes[index])) index = previousCodepointStartSafe(bytes, index);
    return index;
}

fn wordUnderCursor(bytes: []const u8, cursor: usize) ?Range {
    if (bytes.len == 0) return null;
    var at = @min(cursor, bytes.len - 1);
    if (!isWordByte(bytes[at])) return null;
    var start = at;
    while (start > 0) {
        const previous = previousCodepointStartSafe(bytes, start);
        if (!isWordByte(bytes[previous])) break;
        start = previous;
    }
    var end = nextCodepointStart(bytes, at);
    while (end < bytes.len and isWordByte(bytes[end])) end = nextCodepointStart(bytes, end);
    return .{ .start = start, .end = end };
}

'''
if anchor not in s:
    raise SystemExit("missing patch anchor: WORD helper insertion")
s = s.replace(anchor, helpers + anchor, 1)

# Add focused compatibility tests before first later test anchor.
test_anchor = '''test "named numbered yank small-delete and black-hole registers are distinct" {\n'''
new_tests = r'''test "v1 WORD ge viewport line and search motions are Vim-like" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("alpha.beta gamma\n  delta epsilon\nzeta eta theta\nlast line\n");
    editor.currentWindow().viewport_height = 3;

    _ = try editor.handleKey(.{ .codepoint = 'W' });
    try std.testing.expectEqualStrings("gamma", editor.text()[editor.cursor() .. editor.cursor() + 5]);
    _ = try editor.handleKey(.{ .codepoint = 'B' });
    try std.testing.expectEqual(@as(usize, 0), editor.cursor());
    _ = try editor.handleKey(.{ .codepoint = 'E' });
    try std.testing.expectEqual(@as(usize, "alpha.beta".len - 1), editor.cursor());

    editor.setCursor(std.mem.indexOf(u8, editor.text(), "epsilon") orelse unreachable);
    _ = try editor.handleKey(.{ .codepoint = 'g' });
    _ = try editor.handleKey(.{ .codepoint = 'e' });
    try std.testing.expect(editor.cursor() < (std.mem.indexOf(u8, editor.text(), "epsilon") orelse unreachable));

    editor.currentWindow().scroll_line = 1;
    _ = try editor.handleKey(.{ .codepoint = 'H' });
    try std.testing.expectEqual(@as(usize, 2), editor.cursorPosition().line);
    _ = try editor.handleKey(.{ .codepoint = 'L' });
    try std.testing.expectEqual(@as(usize, 4), editor.cursorPosition().line);

    editor.setCursor(0);
    _ = try editor.handleKey(.{ .codepoint = '+' });
    try std.testing.expectEqual(@as(usize, 2), editor.cursorPosition().line);
    _ = try editor.handleKey(.{ .codepoint = '3' });
    _ = try editor.handleKey(.{ .codepoint = '|' });
    try std.testing.expectEqual(@as(usize, 3), editor.cursorPosition().column);

    editor.setCursor(0);
    _ = try editor.handleKey(.{ .codepoint = '*' });
    try std.testing.expectEqual(@as(usize, 0), editor.cursor());
}

test "v1 uppercase edit shortcuts and WORD operators compose" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("one.two three four\nsecond line\n");

    _ = try editor.handleKey(.{ .codepoint = 'd' });
    _ = try editor.handleKey(.{ .codepoint = 'W' });
    try std.testing.expect(std.mem.startsWith(u8, editor.text(), "three"));

    try editor.setText("one two three\n");
    editor.setCursor(std.mem.indexOf(u8, editor.text(), "three") orelse unreachable);
    _ = try editor.handleKey(.{ .codepoint = 'd' });
    _ = try editor.handleKey(.{ .codepoint = 'g' });
    _ = try editor.handleKey(.{ .codepoint = 'e' });
    try std.testing.expect(editor.text().len < "one two three\n".len);

    try editor.setText("abc\ndef\n");
    editor.setCursor(1);
    _ = try editor.handleKey(.{ .codepoint = 'X' });
    try std.testing.expectEqualStrings("bc\ndef\n", editor.text());
    _ = try editor.handleKey(.{ .codepoint = 'D' });
    try std.testing.expectEqualStrings("\ndef\n", editor.text());
}

'''
if test_anchor not in s:
    raise SystemExit("missing patch anchor: parity tests")
s = s.replace(test_anchor, new_tests + test_anchor, 1)

p.write_text(s)
