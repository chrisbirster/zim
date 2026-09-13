#!/usr/bin/env python3
from pathlib import Path

p = Path('src/editor.zig')
s = p.read_text()

bad = '''            .codepoint => |cp| blk: {\n                if (self.pending_g) {\n                    self.pending_g = false;\n                    if (cp == 'e' or cp == 'E') {\n                        const motion_count = self.operator_count * self.takeCount();\n                        const range = self.previousEndMotionRange(cp == 'E', motion_count);\n                        try self.applyOperator(op, range);\n                        break :blk true;\n                    }\n                    self.resetOperator();\n                    break :blk false;\n                }\n                if (cp >= '1' and cp <= '9') {\n                    const slot: usize = @intCast(cp - '0');\n'''
good = '''            .codepoint => |cp| blk: {\n                if (cp >= '1' and cp <= '9') {\n                    const slot: usize = @intCast(cp - '0');\n'''
if bad not in s:
    raise SystemExit('missing pin switcher bad block')
s = s.replace(bad, good, 1)

anchor = '''        return switch (key) {\n            .codepoint => |cp| blk: {\n                if (cp >= '1' and cp <= '9') {\n                    self.count_prefix = self.count_prefix * 10 + @as(usize, @intCast(cp - '0'));\n'''
fixed = '''        return switch (key) {\n            .codepoint => |cp| blk: {\n                if (self.pending_g) {\n                    self.pending_g = false;\n                    if (cp == 'e' or cp == 'E') {\n                        const motion_count = self.operator_count * self.takeCount();\n                        const range = self.previousEndMotionRange(cp == 'E', motion_count);\n                        try self.applyOperator(op, range);\n                        break :blk true;\n                    }\n                    self.resetOperator();\n                    break :blk false;\n                }\n                if (cp >= '1' and cp <= '9') {\n                    self.count_prefix = self.count_prefix * 10 + @as(usize, @intCast(cp - '0'));\n'''
if anchor not in s:
    raise SystemExit('missing operator switch anchor')
s = s.replace(anchor, fixed, 1)

s = s.replace('''        const cursor = self.cursor();\n        if (cursor == 0 or cursor == lineStartAt(self.text(), cursor)) return false;\n        const start = previousCodepointStartSafe(self.text(), cursor);\n        try self.deleteRange(.{ .start = start, .end = cursor });\n''', '''        const cursor_offset = self.cursor();\n        if (cursor_offset == 0 or cursor_offset == lineStartAt(self.text(), cursor_offset)) return false;\n        const start = previousCodepointStartSafe(self.text(), cursor_offset);\n        try self.deleteRange(.{ .start = start, .end = cursor_offset });\n''', 1)
s = s.replace('''    var at = @min(cursor, bytes.len - 1);\n    if (!isWordByte(bytes[at])) return null;\n''', '''    const at = @min(cursor, bytes.len - 1);\n    if (!isWordByte(bytes[at])) return null;\n''', 1)

visual_bad = '''        if (self.pending_g) {\n            self.pending_g = false;\n            if (key == .codepoint and key.codepoint == 'g') {\n                self.moveToLine(0);\n                return true;\n            }\n        }\n'''
visual_good = '''        if (self.pending_g) {\n            self.pending_g = false;\n            switch (key) {\n                .codepoint => |cp| if (cp == 'g') {\n                    self.moveToLine(0);\n                    return true;\n                },\n                else => {},\n            }\n        }\n'''
if visual_bad in s:
    s = s.replace(visual_bad, visual_good, 1)

p.write_text(s)
