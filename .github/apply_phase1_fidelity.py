from pathlib import Path

path = Path('src/editor.zig')
s = path.read_text()

def repl(old: str, new: str, label: str):
    global s
    if old not in s:
        raise SystemExit(f'missing anchor: {label}')
    if s.count(old) != 1:
        raise SystemExit(f'non-unique anchor: {label}: {s.count(old)}')
    s = s.replace(old, new, 1)

# Types and state.
repl('''const FindPending = struct {\n    till: bool,\n    backwards: bool,\n};\n\nconst Range = struct {\n    start: usize,\n    end: usize,\n    kind: RegisterKind = .characterwise,\n};\n''', '''const FindPending = struct {\n    till: bool,\n    backwards: bool,\n    count: usize = 1,\n};\n\nconst Range = struct {\n    start: usize,\n    end: usize,\n    kind: RegisterKind = .characterwise,\n};\n\nconst Location = struct {\n    buffer_id: BufferId,\n    offset: usize,\n};\n\nconst FindRepeat = struct {\n    pending: FindPending,\n    target: u21,\n};\n\nconst RegisterWrite = enum { yank, delete };\n\nconst BlockInsert = struct {\n    first_line: usize,\n    last_line: usize,\n    column: usize,\n};\n\npub const FoldRange = struct {\n    start_line: usize,\n    end_line: usize,\n};\n\nconst FoldSource = enum { manual, provider };\n\npub const Fold = struct {\n    window_id: WindowId,\n    start_line: usize,\n    end_line: usize,\n    closed: bool = false,\n    source: FoldSource = .manual,\n};\n''', 'types')

repl('''    unnamed_register: Register = .{},\n    search_pattern: std.ArrayList(u8) = .empty,\n''', '''    unnamed_register: Register = .{},\n    named_registers: [26]Register = [_]Register{.{}} ** 26,\n    numbered_registers: [10]Register = [_]Register{.{}} ** 10,\n    small_delete_register: Register = .{},\n    selected_register: ?u8 = null,\n    pending_register_select: bool = false,\n\n    macro_registers: [26]std.ArrayList(Key) = [_]std.ArrayList(Key){.empty} ** 26,\n    recording_macro: ?usize = null,\n    replaying_macro: bool = false,\n    last_macro: ?usize = null,\n    pending_macro_record: bool = false,\n    pending_macro_play: bool = false,\n\n    marks: [26]?Location = [_]?Location{null} ** 26,\n    pending_mark_set: bool = false,\n    pending_mark_line: bool = false,\n    pending_mark_exact: bool = false,\n    jump_list: std.ArrayList(Location) = .empty,\n    jump_index: usize = 0,\n    change_list: std.ArrayList(Location) = .empty,\n    change_index: usize = 0,\n\n    search_pattern: std.ArrayList(u8) = .empty,\n''', 'editor state registers')

repl('''    pending_find: ?FindPending = null,\n    pending_g: bool = false,\n    operator_count: usize = 1,\n''', '''    pending_find: ?FindPending = null,\n    last_find: ?FindRepeat = null,\n    pending_g: bool = false,\n    pending_z: bool = false,\n    operator_count: usize = 1,\n\n    folds: std.ArrayList(Fold) = .empty,\n    block_insert: ?BlockInsert = null,\n    block_insert_text: std.ArrayList(u8) = .empty,\n''', 'editor state pending')

# Key vocabulary for jump navigation.
repl('''    ctrl_r,\n    ctrl_v,\n    ctrl_h,\n''', '''    ctrl_r,\n    ctrl_v,\n    ctrl_o,\n    ctrl_i,\n    ctrl_h,\n''', 'key ctrl o i')

# Deinit owned state.
repl('''        self.unnamed_register.deinit(self.allocator);\n        self.search_pattern.deinit(self.allocator);\n''', '''        self.unnamed_register.deinit(self.allocator);\n        for (&self.named_registers) |*register| register.deinit(self.allocator);\n        for (&self.numbered_registers) |*register| register.deinit(self.allocator);\n        self.small_delete_register.deinit(self.allocator);\n        for (&self.macro_registers) |*macro| macro.deinit(self.allocator);\n        self.jump_list.deinit(self.allocator);\n        self.change_list.deinit(self.allocator);\n        self.folds.deinit(self.allocator);\n        self.block_insert_text.deinit(self.allocator);\n        self.search_pattern.deinit(self.allocator);\n''', 'deinit state')

# Macro recording happens before normal dispatch, but q in Normal stops without recording itself.
repl('''    pub fn handleKey(self: *Editor, incoming: Key) anyerror!HandleResult {\n        const key = self.resolveKey(incoming);\n        if (self.recording_change and !self.replaying_change) {\n''', '''    pub fn handleKey(self: *Editor, incoming: Key) anyerror!HandleResult {\n        const key = self.resolveKey(incoming);\n        if (self.recording_macro) |macro_index| {\n            const stop_key = self.mode == .normal and switch (key) {\n                .codepoint => |cp| cp == 'q',\n                else => false,\n            };\n            if (!self.replaying_macro and !stop_key) {\n                try self.macro_registers[macro_index].append(self.allocator, key);\n            }\n        }\n        if (self.recording_change and !self.replaying_change) {\n''', 'handle key macro')

# Ctrl jump path.
repl('''            .ctrl_r => try self.redo(),\n            .ctrl_v => blk: {\n''', '''            .ctrl_r => try self.redo(),\n            .ctrl_o => blk: {\n                _ = self.jumpListMove(-1);\n                break :blk true;\n            },\n            .ctrl_i => blk: {\n                _ = self.jumpListMove(1);\n                break :blk true;\n            },\n            .ctrl_v => blk: {\n''', 'normal ctrl jump')

# Pending prefixes and classic normal-mode commands.
repl('''    fn handleNormalCodepoint(self: *Editor, cp: u21, key: Key) !bool {\n        if (cp >= '1' and cp <= '9') {\n''', '''    fn handleNormalCodepoint(self: *Editor, cp: u21, key: Key) !bool {\n        if (self.pending_register_select) {\n            self.pending_register_select = false;\n            if (isRegisterName(cp)) {\n                self.selected_register = @intCast(cp);\n                return true;\n            }\n            return false;\n        }\n        if (self.pending_macro_record) {\n            self.pending_macro_record = false;\n            const index = letterIndex(cp) orelse return false;\n            self.macro_registers[index].items.len = 0;\n            self.recording_macro = index;\n            self.last_macro = index;\n            self.setStatus("recording @{c}", .{@as(u8, @intCast('a' + index))});\n            return true;\n        }\n        if (self.pending_macro_play) {\n            self.pending_macro_play = false;\n            if (cp == '@') {\n                if (self.last_macro) |index| try self.playMacro(index, self.takeCount());\n                return true;\n            }\n            const index = letterIndex(cp) orelse return false;\n            self.last_macro = index;\n            try self.playMacro(index, self.takeCount());\n            return true;\n        }\n        if (self.pending_mark_set) {\n            self.pending_mark_set = false;\n            const index = letterIndex(cp) orelse return false;\n            self.marks[index] = self.currentLocation();\n            return true;\n        }\n        if (self.pending_mark_line or self.pending_mark_exact) {\n            const linewise = self.pending_mark_line;\n            self.pending_mark_line = false;\n            self.pending_mark_exact = false;\n            const index = letterIndex(cp) orelse return false;\n            return self.jumpToMark(index, linewise);\n        }\n        if (self.pending_z) {\n            self.pending_z = false;\n            return self.handleFoldCommand(cp);\n        }\n        if (self.recording_macro != null and cp == 'q') {\n            self.recording_macro = null;\n            self.setStatus("recording stopped", .{});\n            return true;\n        }\n\n        if (cp >= '1' and cp <= '9') {\n''', 'normal pending prefixes')

# g; / g, changelist.
repl('''        if (self.pending_g) {\n            self.pending_g = false;\n            if (cp == 'g') {\n                self.moveToLine(if (self.count_prefix == 0) 0 else self.takeCount() - 1);\n                self.count_prefix = 0;\n                return true;\n            }\n        }\n''', '''        if (self.pending_g) {\n            self.pending_g = false;\n            if (cp == 'g') {\n                const destination = if (self.count_prefix == 0) 0 else self.takeCount() - 1;\n                const from = self.currentLocation();\n                self.moveToLine(destination);\n                self.recordJump(from, self.currentLocation()) catch {};\n                self.count_prefix = 0;\n                return true;\n            }\n            if (cp == ';') return self.changeListMove(-1);\n            if (cp == ',') return self.changeListMove(1);\n        }\n''', 'pending g')

# Add normal commands before final else.
repl('''            'f' => blk: {\n                self.pending_find = .{ .till = false, .backwards = false };\n                break :blk true;\n            },\n            'F' => blk: {\n                self.pending_find = .{ .till = false, .backwards = true };\n                break :blk true;\n            },\n            't' => blk: {\n                self.pending_find = .{ .till = true, .backwards = false };\n                break :blk true;\n            },\n            'T' => blk: {\n                self.pending_find = .{ .till = true, .backwards = true };\n                break :blk true;\n            },\n            else => false,\n''', '''            'f' => blk: {\n                self.pending_find = .{ .till = false, .backwards = false, .count = count };\n                break :blk true;\n            },\n            'F' => blk: {\n                self.pending_find = .{ .till = false, .backwards = true, .count = count };\n                break :blk true;\n            },\n            't' => blk: {\n                self.pending_find = .{ .till = true, .backwards = false, .count = count };\n                break :blk true;\n            },\n            'T' => blk: {\n                self.pending_find = .{ .till = true, .backwards = true, .count = count };\n                break :blk true;\n            },\n            ';' => blk: {\n                _ = self.repeatFind(false, count);\n                break :blk true;\n            },\n            ',' => blk: {\n                _ = self.repeatFind(true, count);\n                break :blk true;\n            },\n            '%' => blk: {\n                _ = self.matchDelimiter();\n                break :blk true;\n            },\n            '(' => blk: {\n                for (0..count) |_| self.moveSentence(false);\n                break :blk true;\n            },\n            ')' => blk: {\n                for (0..count) |_| self.moveSentence(true);\n                break :blk true;\n            },\n            '{' => blk: {\n                for (0..count) |_| self.moveParagraph(false);\n                break :blk true;\n            },\n            '}' => blk: {\n                for (0..count) |_| self.moveParagraph(true);\n                break :blk true;\n            },\n            '"' => blk: { self.pending_register_select = true; break :blk true; },\n            'q' => blk: { self.pending_macro_record = true; break :blk true; },\n            '@' => blk: { self.pending_macro_play = true; break :blk true; },\n            'm' => blk: { self.pending_mark_set = true; break :blk true; },\n            '\\'' => blk: { self.pending_mark_line = true; break :blk true; },\n            '`' => blk: { self.pending_mark_exact = true; break :blk true; },\n            'z' => blk: { self.pending_z = true; break :blk true; },\n            else => false,\n''', 'normal classic commands')

# Insert-mode block insertion replication.
repl('''            .escape => blk: {\n                self.mode = .normal;\n                self.finishUndoGroup();\n''', '''            .escape => blk: {\n                if (self.block_insert != null) try self.finishBlockInsert();\n                self.mode = .normal;\n                self.finishUndoGroup();\n''', 'insert escape block')

repl('''            .tab => blk: {\n                try self.insertBytes("  ");\n                break :blk true;\n            },\n''', '''            .tab => blk: {\n                if (self.block_insert != null) try self.insertBlockBytes("  ") else try self.insertBytes("  ");\n                break :blk true;\n            },\n''', 'insert tab block')

repl('''            .codepoint => |cp| blk: {\n                if (cp < 0x20) break :blk false;\n                try self.insertCodepoint(cp);\n                break :blk true;\n            },\n''', '''            .codepoint => |cp| blk: {\n                if (cp < 0x20) break :blk false;\n                if (self.block_insert != null) {\n                    var encoded: [4]u8 = undefined;\n                    const len = std.unicode.utf8Encode(cp, &encoded) catch 0;\n                    if (len == 0) break :blk false;\n                    try self.insertBlockBytes(encoded[0..len]);\n                } else {\n                    try self.insertCodepoint(cp);\n                }\n                break :blk true;\n            },\n''', 'insert codepoint block')

# Operator-pending count and text-object count.
repl('''        if (self.pending_text_object) |scope| {\n            return switch (key) {\n                .codepoint => |cp| blk: {\n                    self.pending_text_object = null;\n                    const range = self.textObjectRange(scope, cp) orelse {\n''', '''        if (self.pending_text_object) |scope| {\n            return switch (key) {\n                .codepoint => |cp| blk: {\n                    self.pending_text_object = null;\n                    const object_count = self.operator_count * self.takeCount();\n                    const range = self.textObjectRange(scope, cp, object_count) orelse {\n''', 'text object count')

repl('''            .codepoint => |cp| blk: {\n                if (cp == 'i' or cp == 'a') {\n                    self.pending_text_object = if (cp == 'i') .inner else .around;\n                    break :blk true;\n                }\n''', '''            .codepoint => |cp| blk: {\n                if (cp >= '1' and cp <= '9') {\n                    self.count_prefix = self.count_prefix * 10 + @as(usize, @intCast(cp - '0'));\n                    break :blk true;\n                }\n                if (cp == '0' and self.count_prefix != 0) {\n                    self.count_prefix *= 10;\n                    break :blk true;\n                }\n                if (cp == 'i' or cp == 'a') {\n                    self.pending_text_object = if (cp == 'i') .inner else .around;\n                    break :blk true;\n                }\n''', 'operator count parse')

repl('''                const range = self.motionRange(cp, self.operator_count) orelse {\n''', '''                const motion_count = self.operator_count * self.takeCount();\n                const range = self.motionRange(cp, motion_count) orelse {\n''', 'operator motion count')

# Visual Block semantics + change recording.
repl('''                    'y', 'd', 'c' => {\n                        const op: Operator = if (cp == 'y') .yank else if (cp == 'd') .delete else .change;\n                        const range = self.visualRange();\n                        try self.applyOperator(op, range);\n                    },\n''', '''                    'y', 'd', 'c' => {\n                        const op: Operator = if (cp == 'y') .yank else if (cp == 'd') .delete else .change;\n                        if (op != .yank) try self.beginChange(key);\n                        if (self.mode == .visual_block) {\n                            try self.applyVisualBlockOperator(op);\n                        } else {\n                            const range = self.visualRange();\n                            try self.applyOperator(op, range);\n                        }\n                    },\n                    'I', 'A' => {\n                        if (self.mode != .visual_block) break :blk false;\n                        try self.beginChange(key);\n                        try self.beginBlockInsert(cp == 'A');\n                    },\n''', 'visual block operations')

# motionRange gains classic sentence/paragraph/% targets.
repl('''            '$' => {\n                target = lineEnd(self.text(), start);\n                inclusive = false;\n            },\n            'j', 'k' => {\n''', '''            '$' => {\n                target = lineEnd(self.text(), start);\n                inclusive = false;\n            },\n            '%' => target = matchingDelimiterOffset(self.text(), start) orelse return null,\n            '(', ')' => {\n                for (0..count) |_| target = sentenceBoundary(self.text(), target, cp == ')');\n            },\n            '{', '}' => {\n                for (0..count) |_| target = paragraphBoundary(self.text(), target, cp == '}');\n            },\n            'j', 'k' => {\n''', 'operator classic motions')

# Replace text object implementation with word + paragraph/sentence + delimiter support.
repl('''    fn textObjectRange(self: *const Editor, scope: TextObjectScope, cp: u21) ?Range {\n        const bytes = self.text();\n        const at = self.cursor();\n        if (cp == 'w') {\n''', '''    fn textObjectRange(self: *const Editor, scope: TextObjectScope, cp: u21, count: usize) ?Range {\n        const bytes = self.text();\n        const at = self.cursor();\n        if (cp == 'p') return paragraphTextObject(bytes, at, scope, count);\n        if (cp == 's') return sentenceTextObject(bytes, at, scope, count);\n        if (cp == 'w') {\n''', 'text object signature')

# Register semantics.
repl('''            .yank => {\n                try self.setRegister(range);\n                self.setStatus("yanked", .{});\n''', '''            .yank => {\n                try self.setRegister(range, .yank);\n                self.selected_register = null;\n                self.setStatus("yanked", .{});\n''', 'apply yank register')

repl('''        try self.setRegister(.{ .start = start, .end = end, .kind = range.kind });\n        try self.ensureUndoSnapshot();\n''', '''        try self.setRegister(.{ .start = start, .end = end, .kind = range.kind }, .delete);\n        self.selected_register = null;\n        try self.ensureUndoSnapshot();\n''', 'delete register')

old_reg = '''    fn setRegister(self: *Editor, range: Range) !void {\n        const bytes = self.text();\n        const start = @min(range.start, bytes.len);\n        const end = @min(@max(range.end, start), bytes.len);\n        try self.unnamed_register.set(self.allocator, bytes[start..end], range.kind);\n    }\n\n    fn putRegister(self: *Editor, after: bool) !void {\n        if (self.unnamed_register.bytes.items.len == 0) return;\n        try self.ensureUndoSnapshot();\n        const buffer = self.currentBuffer();\n        var insertion = self.cursor();\n        if (self.unnamed_register.kind == .linewise) {\n            const end = lineEnd(buffer.text.items, insertion);\n            insertion = if (after and end < buffer.text.items.len) end + 1 else lineStartAt(buffer.text.items, insertion);\n        } else if (after and insertion < buffer.text.items.len) {\n            insertion = nextCodepointStart(buffer.text.items, insertion);\n        }\n        try insertSliceAt(buffer, self.allocator, insertion, self.unnamed_register.bytes.items);\n        buffer.markChanged();\n        self.currentWindow().cursor = @min(insertion, buffer.text.items.len);\n    }\n'''
new_reg = '''    fn setRegister(self: *Editor, range: Range, write: RegisterWrite) !void {\n        const bytes = self.text();\n        const start = @min(range.start, bytes.len);\n        const end = @min(@max(range.end, start), bytes.len);\n        try self.writeRegisterBytes(bytes[start..end], range.kind, write);\n    }\n\n    fn writeRegisterBytes(self: *Editor, bytes: []const u8, kind: RegisterKind, write: RegisterWrite) !void {\n        if (self.selected_register == '_') return;\n\n        if (self.selected_register) |name| {\n            if (letterIndex(name)) |index| {\n                if (name >= 'A' and name <= 'Z') {\n                    try self.named_registers[index].bytes.appendSlice(self.allocator, bytes);\n                    self.named_registers[index].kind = kind;\n                } else {\n                    try self.named_registers[index].set(self.allocator, bytes, kind);\n                }\n            }\n        }\n\n        try self.unnamed_register.set(self.allocator, bytes, kind);\n        switch (write) {\n            .yank => try self.numbered_registers[0].set(self.allocator, bytes, kind),\n            .delete => {\n                const large = kind == .linewise or std.mem.indexOfScalar(u8, bytes, '\\n') != null;\n                if (large) {\n                    var index: usize = 9;\n                    while (index > 1) : (index -= 1) {\n                        try self.numbered_registers[index].set(\n                            self.allocator,\n                            self.numbered_registers[index - 1].bytes.items,\n                            self.numbered_registers[index - 1].kind,\n                        );\n                    }\n                    try self.numbered_registers[1].set(self.allocator, bytes, kind);\n                } else {\n                    try self.small_delete_register.set(self.allocator, bytes, kind);\n                }\n            },\n        }\n    }\n\n    fn readRegister(self: *Editor) *Register {\n        const selected = self.selected_register orelse return &self.unnamed_register;\n        if (letterIndex(selected)) |index| return &self.named_registers[index];\n        if (selected >= '0' and selected <= '9') return &self.numbered_registers[selected - '0'];\n        if (selected == '-') return &self.small_delete_register;\n        return &self.unnamed_register;\n    }\n\n    fn putRegister(self: *Editor, after: bool) !void {\n        const register = self.readRegister();\n        if (register.bytes.items.len == 0) return;\n        const register_kind = register.kind;\n        const payload = try self.allocator.dupe(u8, register.bytes.items);\n        defer self.allocator.free(payload);\n        try self.ensureUndoSnapshot();\n        const buffer = self.currentBuffer();\n        var insertion = self.cursor();\n        if (register_kind == .linewise) {\n            const end = lineEnd(buffer.text.items, insertion);\n            insertion = if (after and end < buffer.text.items.len) end + 1 else lineStartAt(buffer.text.items, insertion);\n        } else if (after and insertion < buffer.text.items.len) {\n            insertion = nextCodepointStart(buffer.text.items, insertion);\n        }\n        try insertSliceAt(buffer, self.allocator, insertion, payload);\n        buffer.markChanged();\n        self.currentWindow().cursor = @min(insertion, buffer.text.items.len);\n    }\n'''
repl(old_reg, new_reg, 'register subsystem')

# Clear selected register after complete put sequence.
repl('''                for (0..count) |_| try self.putRegister(cp == 'p');\n                self.finishUndoGroup();\n''', '''                for (0..count) |_| try self.putRegister(cp == 'p');\n                self.selected_register = null;\n                self.finishUndoGroup();\n''', 'put selected clear')

# Find repeat/count.
start = s.index('    fn finishFind(self: *Editor, pending: FindPending, cp: u21) bool {')
end = s.index('\n    fn search(self: *Editor, forward: bool) bool {', start)
s = s[:start] + '''    fn finishFind(self: *Editor, pending: FindPending, cp: u21) bool {\n        const moved = self.performFind(pending, cp);\n        if (moved) self.last_find = .{ .pending = pending, .target = cp };\n        return true;\n    }\n\n    fn performFind(self: *Editor, pending: FindPending, cp: u21) bool {\n        if (cp > 0x7f) return false;\n        const target: u8 = @intCast(cp);\n        var remaining = pending.count;\n        var cursor = self.cursor();\n        while (remaining > 0) : (remaining -= 1) {\n            const bytes = self.text();\n            const start_line = lineStartAt(bytes, cursor);\n            const end_line = lineEnd(bytes, cursor);\n            var found: ?usize = null;\n            if (pending.backwards) {\n                if (cursor <= start_line) return false;\n                var index = cursor;\n                while (index > start_line) {\n                    index -= 1;\n                    if (bytes[index] == target) { found = index; break; }\n                }\n            } else {\n                var index = @min(cursor + 1, end_line);\n                while (index < end_line) : (index += 1) {\n                    if (bytes[index] == target) { found = index; break; }\n                }\n            }\n            const match = found orelse return false;\n            cursor = match;\n        }\n        if (pending.till) {\n            self.currentWindow().cursor = if (pending.backwards) nextCodepointStart(self.text(), cursor) else previousCodepointStartSafe(self.text(), cursor);\n        } else {\n            self.currentWindow().cursor = cursor;\n        }\n        return true;\n    }\n\n    fn repeatFind(self: *Editor, reverse: bool, count: usize) bool {\n        const repeat = self.last_find orelse return false;\n        var pending = repeat.pending;\n        pending.backwards = if (reverse) !pending.backwards else pending.backwards;\n        pending.count = count;\n        return self.performFind(pending, repeat.target);\n    }\n''' + s[end:]

# Search becomes a jump.
repl('''            if (std.mem.indexOfPos(u8, bytes, from, pattern)) |index| {\n                self.currentWindow().cursor = index;\n                return true;\n            }\n''', '''            if (std.mem.indexOfPos(u8, bytes, from, pattern)) |index| {\n                const origin = self.currentLocation();\n                self.currentWindow().cursor = index;\n                self.recordJump(origin, self.currentLocation()) catch {};\n                return true;\n            }\n''', 'search forward jump')
repl('''            if (std.mem.lastIndexOf(u8, bytes[0..upto], pattern)) |index| {\n                self.currentWindow().cursor = index;\n                return true;\n            }\n''', '''            if (std.mem.lastIndexOf(u8, bytes[0..upto], pattern)) |index| {\n                const origin = self.currentLocation();\n                self.currentWindow().cursor = index;\n                self.recordJump(origin, self.currentLocation()) catch {};\n                return true;\n            }\n''', 'search backward jump')

# Changelist records once per undo group.
repl('''    fn ensureUndoSnapshot(self: *Editor) !void {\n        if (self.undo_group_active) return;\n        try self.currentBuffer().recordUndo(self.allocator, self.cursor());\n''', '''    fn ensureUndoSnapshot(self: *Editor) !void {\n        if (self.undo_group_active) return;\n        try self.recordChangeLocation(self.currentLocation());\n        try self.currentBuffer().recordUndo(self.allocator, self.cursor());\n''', 'changelist record')

# Reset all pending prefix state.
repl('''        self.pending_find = null;\n        self.pending_g = false;\n        self.count_prefix = 0;\n''', '''        self.pending_find = null;\n        self.pending_g = false;\n        self.pending_z = false;\n        self.pending_register_select = false;\n        self.pending_macro_record = false;\n        self.pending_macro_play = false;\n        self.pending_mark_set = false;\n        self.pending_mark_line = false;\n        self.pending_mark_exact = false;\n        self.selected_register = null;\n        self.count_prefix = 0;\n''', 'reset pending')

# Insert major fidelity methods before allocator ids.
anchor = '    fn allocateBufferId(self: *Editor) BufferId {'
methods = r'''    fn currentLocation(self: *const Editor) Location {
        return .{ .buffer_id = self.currentWindowConst().buffer_id, .offset = self.cursor() };
    }

    fn locationsEqual(a: Location, b: Location) bool {
        return a.buffer_id == b.buffer_id and a.offset == b.offset;
    }

    fn goToLocation(self: *Editor, location: Location, linewise: bool) bool {
        const buffer = self.bufferById(location.buffer_id) orelse return false;
        self.currentWindow().buffer_id = location.buffer_id;
        const offset = @min(location.offset, buffer.text.items.len);
        self.currentWindow().cursor = if (linewise)
            firstNonBlank(buffer.text.items, lineStartAt(buffer.text.items, offset))
        else
            offset;
        return true;
    }

    fn recordJump(self: *Editor, origin: Location, destination: Location) !void {
        if (locationsEqual(origin, destination)) return;
        if (self.jump_index < self.jump_list.items.len) self.jump_list.items.len = self.jump_index;
        if (self.jump_list.items.len == 0 or !locationsEqual(self.jump_list.items[self.jump_list.items.len - 1], origin)) {
            try self.jump_list.append(self.allocator, origin);
        }
        try self.jump_list.append(self.allocator, destination);
        self.jump_index = self.jump_list.items.len - 1;
    }

    fn jumpListMove(self: *Editor, direction: i8) bool {
        if (self.jump_list.items.len == 0) return false;
        if (direction < 0) {
            if (self.jump_index == 0) return false;
            self.jump_index -= 1;
        } else {
            if (self.jump_index + 1 >= self.jump_list.items.len) return false;
            self.jump_index += 1;
        }
        return self.goToLocation(self.jump_list.items[self.jump_index], false);
    }

    fn recordChangeLocation(self: *Editor, location: Location) !void {
        if (self.change_index < self.change_list.items.len) self.change_list.items.len = self.change_index;
        if (self.change_list.items.len == 0 or !locationsEqual(self.change_list.items[self.change_list.items.len - 1], location)) {
            try self.change_list.append(self.allocator, location);
        }
        self.change_index = self.change_list.items.len;
    }

    fn changeListMove(self: *Editor, direction: i8) bool {
        if (self.change_list.items.len == 0) return false;
        if (direction < 0) {
            if (self.change_index == 0) return false;
            self.change_index -= 1;
        } else {
            if (self.change_index >= self.change_list.items.len) return false;
            self.change_index += 1;
            if (self.change_index >= self.change_list.items.len) return false;
        }
        return self.goToLocation(self.change_list.items[self.change_index], false);
    }

    fn jumpToMark(self: *Editor, index: usize, linewise: bool) bool {
        const destination = self.marks[index] orelse return false;
        const origin = self.currentLocation();
        if (!self.goToLocation(destination, linewise)) return false;
        self.recordJump(origin, self.currentLocation()) catch {};
        return true;
    }

    fn playMacro(self: *Editor, index: usize, count: usize) !void {
        if (self.macro_registers[index].items.len == 0) return;
        const keys = try self.allocator.dupe(Key, self.macro_registers[index].items);
        defer self.allocator.free(keys);
        self.replaying_macro = true;
        defer self.replaying_macro = false;
        for (0..count) |_| for (keys) |macro_key| _ = try self.handleKey(macro_key);
    }

    fn matchDelimiter(self: *Editor) bool {
        const destination = matchingDelimiterOffset(self.text(), self.cursor()) orelse return false;
        const origin = self.currentLocation();
        self.currentWindow().cursor = destination;
        self.recordJump(origin, self.currentLocation()) catch {};
        return true;
    }

    fn moveSentence(self: *Editor, forward: bool) void {
        self.currentWindow().cursor = sentenceBoundary(self.text(), self.cursor(), forward);
    }

    fn moveParagraph(self: *Editor, forward: bool) void {
        self.currentWindow().cursor = paragraphBoundary(self.text(), self.cursor(), forward);
    }

    fn blockGeometry(self: *const Editor) struct { first_line: usize, last_line: usize, left_column: usize, right_column: usize } {
        const anchor = self.visual_anchor orelse self.cursor();
        const a = positionForOffset(self.text(), anchor);
        const b = positionForOffset(self.text(), self.cursor());
        return .{
            .first_line = @min(a.line, b.line) - 1,
            .last_line = @max(a.line, b.line) - 1,
            .left_column = @min(a.column, b.column) - 1,
            .right_column = @max(a.column, b.column) - 1,
        };
    }

    fn collectBlockRanges(self: *const Editor, allocator: std.mem.Allocator) !std.ArrayList(Range) {
        const geometry = self.blockGeometry();
        var ranges: std.ArrayList(Range) = .empty;
        errdefer ranges.deinit(allocator);
        for (geometry.first_line..geometry.last_line + 1) |line| {
            const start = offsetForLineCodepointColumn(self.text(), line, geometry.left_column);
            const line_end = lineEnd(self.text(), start);
            if (start >= line_end) continue;
            const right = offsetForLineCodepointColumn(self.text(), line, geometry.right_column);
            const end = if (right < line_end) nextCodepointStart(self.text(), right) else line_end;
            try ranges.append(allocator, .{ .start = start, .end = @max(start, end), .kind = .blockwise });
        }
        return ranges;
    }

    fn applyVisualBlockOperator(self: *Editor, op: Operator) !void {
        var ranges = try self.collectBlockRanges(self.allocator);
        defer ranges.deinit(self.allocator);
        if (ranges.items.len == 0) return;

        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        for (ranges.items, 0..) |range, index| {
            if (index != 0) try payload.append(self.allocator, '\n');
            try payload.appendSlice(self.allocator, self.text()[range.start..range.end]);
        }
        try self.writeRegisterBytes(payload.items, .blockwise, if (op == .yank) .yank else .delete);
        self.selected_register = null;

        if (op == .yank) {
            self.mode = .normal;
            self.visual_anchor = null;
            self.setStatus("yanked block", .{});
            return;
        }

        try self.ensureUndoSnapshot();
        var index = ranges.items.len;
        while (index > 0) {
            index -= 1;
            self.deleteRawRange(ranges.items[index]);
        }
        self.currentBuffer().markChanged();
        self.currentWindow().cursor = @min(ranges.items[0].start, self.text().len);
        const geometry = self.blockGeometry();
        self.visual_anchor = null;
        if (op == .change) {
            self.block_insert = .{ .first_line = geometry.first_line, .last_line = geometry.last_line, .column = geometry.left_column };
            self.block_insert_text.items.len = 0;
            self.mode = .insert;
        } else {
            self.mode = .normal;
            self.finishUndoGroup();
            if (self.recording_change) try self.finishChange();
        }
    }

    fn deleteRawRange(self: *Editor, range: Range) void {
        const buffer = self.currentBuffer();
        const start = @min(range.start, buffer.text.items.len);
        const end = @min(@max(range.end, start), buffer.text.items.len);
        if (start == end) return;
        const old_len = buffer.text.items.len;
        std.mem.copyForwards(u8, buffer.text.items[start .. old_len - (end - start)], buffer.text.items[end..old_len]);
        buffer.text.items.len = old_len - (end - start);
    }

    fn beginBlockInsert(self: *Editor, append_right: bool) !void {
        const geometry = self.blockGeometry();
        const column = geometry.left_column + (if (append_right) geometry.right_column - geometry.left_column + 1 else 0);
        self.block_insert = .{ .first_line = geometry.first_line, .last_line = geometry.last_line, .column = column };
        self.block_insert_text.items.len = 0;
        self.currentWindow().cursor = offsetForLineCodepointColumn(self.text(), geometry.first_line, column);
        self.visual_anchor = null;
        self.mode = .insert;
    }

    fn insertBlockBytes(self: *Editor, bytes: []const u8) !void {
        try self.insertBytes(bytes);
        try self.block_insert_text.appendSlice(self.allocator, bytes);
    }

    fn finishBlockInsert(self: *Editor) !void {
        const block = self.block_insert orelse return;
        self.block_insert = null;
        if (self.block_insert_text.items.len == 0) return;
        const payload = try self.allocator.dupe(u8, self.block_insert_text.items);
        defer self.allocator.free(payload);
        for (block.first_line + 1..block.last_line + 1) |line| {
            const insertion = offsetForLineCodepointColumn(self.text(), line, block.column);
            try insertSliceAt(self.currentBuffer(), self.allocator, insertion, payload);
        }
        self.currentBuffer().markChanged();
        self.block_insert_text.items.len = 0;
    }

    pub fn addManualFold(self: *Editor, start_line: usize, end_line: usize) !void {
        if (end_line <= start_line) return;
        try self.folds.append(self.allocator, .{
            .window_id = self.currentWindow().id,
            .start_line = start_line,
            .end_line = end_line,
            .closed = false,
            .source = .manual,
        });
    }

    pub fn replaceProviderFolds(self: *Editor, ranges: []const FoldRange) !void {
        const window_id = self.currentWindow().id;
        var write: usize = 0;
        for (self.folds.items) |fold| {
            if (!(fold.window_id == window_id and fold.source == .provider)) {
                self.folds.items[write] = fold;
                write += 1;
            }
        }
        self.folds.items.len = write;
        for (ranges) |range| {
            if (range.end_line <= range.start_line) continue;
            try self.folds.append(self.allocator, .{
                .window_id = window_id,
                .start_line = range.start_line,
                .end_line = range.end_line,
                .source = .provider,
            });
        }
    }

    pub fn lineHiddenByFold(self: *const Editor, window_id: WindowId, line: usize) bool {
        for (self.folds.items) |fold| {
            if (fold.window_id == window_id and fold.closed and line > fold.start_line and line <= fold.end_line) return true;
        }
        return false;
    }

    fn handleFoldCommand(self: *Editor, cp: u21) bool {
        const line = self.cursorPosition().line - 1;
        switch (cp) {
            'M' => { for (self.folds.items) |*fold| if (fold.window_id == self.currentWindow().id) fold.closed = true; return true; },
            'R' => { for (self.folds.items) |*fold| if (fold.window_id == self.currentWindow().id) fold.closed = false; return true; },
            'a', 'c', 'o' => {
                var best: ?*Fold = null;
                for (self.folds.items) |*fold| {
                    if (fold.window_id != self.currentWindow().id or line < fold.start_line or line > fold.end_line) continue;
                    if (best == null or (fold.end_line - fold.start_line) < (best.?.end_line - best.?.start_line)) best = fold;
                }
                const fold = best orelse return true;
                if (cp == 'a') fold.closed = !fold.closed else fold.closed = cp == 'c';
                return true;
            },
            else => return false,
        }
    }

'''
if anchor not in s: raise SystemExit('missing allocate anchor')
s = s.replace(anchor, methods + anchor, 1)

# Global helpers for registers, classic objects/motions and UTF-8 block columns.
anchor2 = 'const DelimiterPair = struct { open: u8, close: u8 };\n'
helpers = r'''fn letterIndex(cp: u21) ?usize {
    if (cp >= 'a' and cp <= 'z') return @intCast(cp - 'a');
    if (cp >= 'A' and cp <= 'Z') return @intCast(cp - 'A');
    return null;
}

fn isRegisterName(cp: u21) bool {
    return letterIndex(cp) != null or (cp >= '0' and cp <= '9') or cp == '-' or cp == '_';
}

fn offsetForLineCodepointColumn(bytes: []const u8, line_index: usize, column: usize) usize {
    const start = offsetForLineColumn(bytes, line_index, 0);
    const end = lineEnd(bytes, start);
    var cursor = start;
    var current: usize = 0;
    while (cursor < end and current < column) : (current += 1) cursor = nextCodepointStart(bytes, cursor);
    return cursor;
}

fn isBlankLine(bytes: []const u8, start: usize) bool {
    const end = lineEnd(bytes, start);
    for (bytes[start..end]) |byte| if (byte != ' ' and byte != '\t' and byte != '\r') return false;
    return true;
}

fn nextLineStart(bytes: []const u8, start: usize) usize {
    const end = lineEnd(bytes, start);
    return if (end < bytes.len) end + 1 else bytes.len;
}

fn paragraphBounds(bytes: []const u8, at: usize) ?Range {
    if (bytes.len == 0) return null;
    var line_start = lineStartAt(bytes, @min(at, bytes.len));
    while (line_start < bytes.len and isBlankLine(bytes, line_start)) line_start = nextLineStart(bytes, line_start);
    if (line_start >= bytes.len) return null;
    var start = line_start;
    while (start > 0) {
        const previous_end = start - 1;
        const previous_start = lineStartAt(bytes, previous_end);
        if (isBlankLine(bytes, previous_start)) break;
        start = previous_start;
    }
    var end = line_start;
    while (end < bytes.len and !isBlankLine(bytes, end)) end = nextLineStart(bytes, end);
    return .{ .start = start, .end = end, .kind = .linewise };
}

fn paragraphTextObject(bytes: []const u8, at: usize, scope: TextObjectScope, count: usize) ?Range {
    var current = paragraphBounds(bytes, at) orelse return null;
    var remaining = if (count == 0) 1 else count;
    while (remaining > 1) : (remaining -= 1) {
        var probe = current.end;
        while (probe < bytes.len and isBlankLine(bytes, probe)) probe = nextLineStart(bytes, probe);
        const next = paragraphBounds(bytes, probe) orelse break;
        current.end = next.end;
    }
    if (scope == .around) {
        var end = current.end;
        while (end < bytes.len and isBlankLine(bytes, end)) end = nextLineStart(bytes, end);
        if (end != current.end) current.end = end else {
            var start = current.start;
            while (start > 0) {
                const previous_start = lineStartAt(bytes, start - 1);
                if (!isBlankLine(bytes, previous_start)) break;
                start = previous_start;
            }
            current.start = start;
        }
    }
    return current;
}

fn isSentenceTerminator(byte: u8) bool { return byte == '.' or byte == '!' or byte == '?'; }

fn sentenceStart(bytes: []const u8, at: usize) usize {
    var index = @min(at, bytes.len);
    while (index > 0) {
        const previous = previousCodepointStartSafe(bytes, index);
        if (isSentenceTerminator(bytes[previous])) {
            var probe = nextCodepointStart(bytes, previous);
            if (probe >= bytes.len or isSpaceByte(bytes[probe])) {
                while (probe < bytes.len and isSpaceByte(bytes[probe])) probe = nextCodepointStart(bytes, probe);
                return probe;
            }
        }
        index = previous;
    }
    while (index < bytes.len and isSpaceByte(bytes[index])) index = nextCodepointStart(bytes, index);
    return index;
}

fn sentenceEnd(bytes: []const u8, start: usize) usize {
    var index = @min(start, bytes.len);
    while (index < bytes.len) {
        if (isSentenceTerminator(bytes[index])) return nextCodepointStart(bytes, index);
        index = nextCodepointStart(bytes, index);
    }
    return bytes.len;
}

fn sentenceTextObject(bytes: []const u8, at: usize, scope: TextObjectScope, count: usize) ?Range {
    if (bytes.len == 0) return null;
    const start = sentenceStart(bytes, at);
    if (start >= bytes.len) return null;
    var end = sentenceEnd(bytes, start);
    var remaining = if (count == 0) 1 else count;
    while (remaining > 1 and end < bytes.len) : (remaining -= 1) {
        var next = end;
        while (next < bytes.len and isSpaceByte(bytes[next])) next = nextCodepointStart(bytes, next);
        end = sentenceEnd(bytes, next);
    }
    if (scope == .around) while (end < bytes.len and isSpaceByte(bytes[end])) end = nextCodepointStart(bytes, end);
    return .{ .start = start, .end = end };
}

fn sentenceBoundary(bytes: []const u8, at: usize, forward: bool) usize {
    if (forward) {
        var end = sentenceEnd(bytes, @min(at +| 1, bytes.len));
        while (end < bytes.len and isSpaceByte(bytes[end])) end = nextCodepointStart(bytes, end);
        return end;
    }
    const start = sentenceStart(bytes, at);
    if (start == 0) return 0;
    return sentenceStart(bytes, previousCodepointStartSafe(bytes, start));
}

fn paragraphBoundary(bytes: []const u8, at: usize, forward: bool) usize {
    if (forward) {
        const current = paragraphBounds(bytes, at) orelse return bytes.len;
        var probe = current.end;
        while (probe < bytes.len and isBlankLine(bytes, probe)) probe = nextLineStart(bytes, probe);
        return probe;
    }
    const current = paragraphBounds(bytes, at) orelse return 0;
    if (current.start == 0) return 0;
    var probe = current.start;
    while (probe > 0) {
        const previous = lineStartAt(bytes, probe - 1);
        if (!isBlankLine(bytes, previous)) return paragraphBounds(bytes, previous).?.start;
        probe = previous;
    }
    return 0;
}

fn matchingDelimiterOffset(bytes: []const u8, at: usize) ?usize {
    if (bytes.len == 0) return null;
    var cursor = @min(at, bytes.len - 1);
    const line_end = lineEnd(bytes, cursor);
    while (cursor < line_end and std.mem.indexOfScalar(u8, "()[]{}", bytes[cursor]) == null) cursor += 1;
    if (cursor >= bytes.len or std.mem.indexOfScalar(u8, "()[]{}", bytes[cursor]) == null) return null;
    const ch = bytes[cursor];
    const pair: u8 = switch (ch) { '(' => ')', '[' => ']', '{' => '}', ')' => '(', ']' => '[', '}' => '{', else => return null };
    const forward = ch == '(' or ch == '[' or ch == '{';
    var depth: usize = 1;
    var index = cursor;
    while (true) {
        if (forward) {
            if (index + 1 >= bytes.len) return null;
            index += 1;
        } else {
            if (index == 0) return null;
            index -= 1;
        }
        if (bytes[index] == ch) depth += 1 else if (bytes[index] == pair) {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
}

'''
if anchor2 not in s: raise SystemExit('missing delimiter anchor')
s = s.replace(anchor2, helpers + anchor2, 1)

# Tests: fidelity sequences + registers/macros/marks/block/folds.
tests = r'''

test "classic paragraph sentence objects and operator counts compose" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("one two. Three four!\n\nalpha beta\ngamma\n\ndelta\n");
    _ = try editor.handleKey(.{ .codepoint = 'd' });
    _ = try editor.handleKey(.{ .codepoint = 'a' });
    _ = try editor.handleKey(.{ .codepoint = 's' });
    try std.testing.expect(std.mem.startsWith(u8, editor.text(), "Three four!"));
    try editor.setText("p1\n\np2\n\np3\n");
    _ = try editor.handleKey(.{ .codepoint = '2' });
    _ = try editor.handleKey(.{ .codepoint = 'd' });
    _ = try editor.handleKey(.{ .codepoint = 'a' });
    _ = try editor.handleKey(.{ .codepoint = 'p' });
    try std.testing.expectEqualStrings("p3\n", editor.text());
}

test "classic find repeat percent and operator post-counts behave like Vim" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("a,b,c,d (x[y]z) words here now");
    _ = try editor.handleKey(.{ .codepoint = '3' });
    _ = try editor.handleKey(.{ .codepoint = 'f' });
    _ = try editor.handleKey(.{ .codepoint = ',' });
    try std.testing.expectEqual(@as(usize, 5), editor.cursor());
    _ = try editor.handleKey(.{ .codepoint = ';' });
    try std.testing.expectEqual(@as(usize, 7), editor.cursor());
    _ = try editor.handleKey(.{ .codepoint = ',' });
    try std.testing.expectEqual(@as(usize, 5), editor.cursor());
    editor.setCursor(8);
    _ = try editor.handleKey(.{ .codepoint = '%' });
    try std.testing.expect(editor.cursor() > 8);
    editor.setCursor(editor.text().len - "words here now".len);
    _ = try editor.handleKey(.{ .codepoint = 'd' });
    _ = try editor.handleKey(.{ .codepoint = '2' });
    _ = try editor.handleKey(.{ .codepoint = 'w' });
    try std.testing.expect(std.mem.endsWith(u8, editor.text(), "now"));
}

test "named numbered yank small-delete and black-hole registers are distinct" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("alpha beta\nsecond\n");
    _ = try editor.handleKey(.{ .codepoint = '"' }); _ = try editor.handleKey(.{ .codepoint = 'a' });
    _ = try editor.handleKey(.{ .codepoint = 'y' }); _ = try editor.handleKey(.{ .codepoint = 'i' }); _ = try editor.handleKey(.{ .codepoint = 'w' });
    try std.testing.expectEqualStrings("alpha", editor.named_registers[0].bytes.items);
    try std.testing.expectEqualStrings("alpha", editor.numbered_registers[0].bytes.items);
    _ = try editor.handleKey(.{ .codepoint = 'x' });
    try std.testing.expect(editor.small_delete_register.bytes.items.len > 0);
    const unnamed_before = try std.testing.allocator.dupe(u8, editor.unnamed_register.bytes.items); defer std.testing.allocator.free(unnamed_before);
    _ = try editor.handleKey(.{ .codepoint = '"' }); _ = try editor.handleKey(.{ .codepoint = '_' });
    _ = try editor.handleKey(.{ .codepoint = 'd' }); _ = try editor.handleKey(.{ .codepoint = 'd' });
    try std.testing.expectEqualStrings(unnamed_before, editor.unnamed_register.bytes.items);
}

test "macros marks jumplist and changelist provide familiar navigation" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("abc\ndef\nghi\n");
    _ = try editor.handleKey(.{ .codepoint = 'q' }); _ = try editor.handleKey(.{ .codepoint = 'a' });
    _ = try editor.handleKey(.{ .codepoint = 'l' }); _ = try editor.handleKey(.{ .codepoint = 'l' });
    _ = try editor.handleKey(.{ .codepoint = 'q' });
    editor.setCursor(0);
    _ = try editor.handleKey(.{ .codepoint = '@' }); _ = try editor.handleKey(.{ .codepoint = 'a' });
    try std.testing.expectEqual(@as(usize, 2), editor.cursor());
    _ = try editor.handleKey(.{ .codepoint = 'm' }); _ = try editor.handleKey(.{ .codepoint = 'a' });
    editor.setCursor(editor.text().len);
    _ = try editor.handleKey(.{ .codepoint = '`' }); _ = try editor.handleKey(.{ .codepoint = 'a' });
    try std.testing.expectEqual(@as(usize, 2), editor.cursor());
    _ = try editor.handleKey(.ctrl_o);
    try std.testing.expect(editor.cursor() > 2);
    _ = try editor.handleKey(.ctrl_i);
    try std.testing.expectEqual(@as(usize, 2), editor.cursor());
}

test "visual block delete and insert are rectangular and UTF-8 safe" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("aλc\ndλf\ngλi\n");
    editor.setCursorFromLineColumn(0, 1);
    _ = try editor.handleKey(.ctrl_v);
    _ = try editor.handleKey(.{ .codepoint = 'j' });
    _ = try editor.handleKey(.{ .codepoint = 'j' });
    _ = try editor.handleKey(.{ .codepoint = 'd' });
    try std.testing.expectEqualStrings("ac\ndf\ngi\n", editor.text());
    editor.setCursorFromLineColumn(0, 1);
    _ = try editor.handleKey(.ctrl_v); _ = try editor.handleKey(.{ .codepoint = 'j' }); _ = try editor.handleKey(.{ .codepoint = 'j' });
    _ = try editor.handleKey(.{ .codepoint = 'I' }); _ = try editor.handleKey(.{ .codepoint = 'X' }); _ = try editor.handleKey(.escape);
    try std.testing.expectEqualStrings("aXc\ndXf\ngXi\n", editor.text());
}

test "fold commands own visibility independently of providers" {
    var editor = try Editor.init(std.testing.allocator, std.testing.io, null);
    defer editor.deinit();
    try editor.setText("one\ntwo\nthree\nfour\n");
    try editor.addManualFold(0, 2);
    _ = try editor.handleKey(.{ .codepoint = 'z' }); _ = try editor.handleKey(.{ .codepoint = 'c' });
    try std.testing.expect(editor.lineHiddenByFold(editor.currentWindow().id, 1));
    _ = try editor.handleKey(.{ .codepoint = 'z' }); _ = try editor.handleKey(.{ .codepoint = 'o' });
    try std.testing.expect(!editor.lineHiddenByFold(editor.currentWindow().id, 1));
    try editor.replaceProviderFolds(&.{.{ .start_line = 1, .end_line = 3 }});
    _ = try editor.handleKey(.{ .codepoint = 'z' }); _ = try editor.handleKey(.{ .codepoint = 'M' });
    try std.testing.expect(editor.lineHiddenByFold(editor.currentWindow().id, 2));
    _ = try editor.handleKey(.{ .codepoint = 'z' }); _ = try editor.handleKey(.{ .codepoint = 'R' });
    try std.testing.expect(!editor.lineHiddenByFold(editor.currentWindow().id, 2));
}
'''
s += tests
path.write_text(s)

# Update EditorView translation for the newly normalized jump keys. Hondo patch will supply them.
view = Path('src/editor_view.zig')
v = view.read_text()
old = '''        .ctrl_r => .ctrl_r,\n        .ctrl_v => .ctrl_v,\n        .ctrl_h => .ctrl_h,\n'''
if old in v:
    v = v.replace(old, '''        .ctrl_r => .ctrl_r,\n        .ctrl_v => .ctrl_v,\n        .ctrl_o => .ctrl_o,\n        .ctrl_i => .ctrl_i,\n        .ctrl_h => .ctrl_h,\n''', 1)
view.write_text(v)

# Reconcile docs without claiming language integration has landed yet.
readme = Path('README.md')
r = readme.read_text()
if '## Neovim fidelity status' not in r:
    r += '''\n\n## Neovim fidelity status\n\nThe editor core now owns classic motions/operators/counts, paragraph and sentence text objects, Vim-style registers, macros, marks, jump/change history, rectangular Visual Block editing, and provider-independent fold state. Tree-sitter remains a separate language service until PR #15 lands; it augments rather than replaces classic Vim grammar.\n'''
readme.write_text(r)

roadmap = Path('ROADMAP.md')
rr = roadmap.read_text()
if '### Editor fidelity convergence' not in rr:
    rr += '''\n\n### Editor fidelity convergence\n\n- [x] paragraph/sentence classic text objects\n- [x] `%`, find-repeat, sentence/paragraph motions and operator/count composition\n- [x] named/numbered/yank/small-delete/black-hole register model\n- [x] macros, marks, jumplist and changelist foundation\n- [x] rectangular Visual Block edit/yank/delete/change/insert semantics\n- [x] provider-independent fold state and `za/zc/zo/zM/zR` commands\n- [ ] Tree-sitter service merged and wired into EditorView\n'''
roadmap.write_text(rr)

# The helper files are deleted by the workflow after execution.
print('phase1 fidelity transformation applied')
