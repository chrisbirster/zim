from pathlib import Path

path = Path('src/editor.zig')
text = path.read_text()

replacements = [
    ('        var cursor = self.cursor();\n', '        var scan_cursor = self.cursor();\n'),
    ('            const start_line = lineStartAt(bytes, cursor);\n            const end_line = lineEnd(bytes, cursor);\n', '            const start_line = lineStartAt(bytes, scan_cursor);\n            const end_line = lineEnd(bytes, scan_cursor);\n'),
    ('                if (cursor <= start_line) return false;\n                var index = cursor;\n', '                if (scan_cursor <= start_line) return false;\n                var index = scan_cursor;\n'),
    ('                var index = @min(cursor + 1, end_line);\n', '                var index = @min(scan_cursor + 1, end_line);\n'),
    ('            cursor = match;\n', '            scan_cursor = match;\n'),
    ('            self.currentWindow().cursor = if (pending.backwards) nextCodepointStart(self.text(), cursor) else previousCodepointStartSafe(self.text(), cursor);\n        } else {\n            self.currentWindow().cursor = cursor;\n', '            self.currentWindow().cursor = if (pending.backwards) nextCodepointStart(self.text(), scan_cursor) else previousCodepointStartSafe(self.text(), scan_cursor);\n        } else {\n            self.currentWindow().cursor = scan_cursor;\n'),
    ('        for (0..count) |_| for (keys) |macro_key| _ = try self.handleKey(macro_key);\n', '        for (0..count) |_| {\n            for (keys) |macro_key| {\n                _ = try self.handleKey(macro_key);\n            }\n        }\n'),
    ("                for (self.folds.items) |*fold| if (fold.window_id == self.currentWindow().id) fold.closed = true;\n", "                for (self.folds.items) |*fold| {\n                    if (fold.window_id == self.currentWindow().id) fold.closed = true;\n                }\n"),
    ("                for (self.folds.items) |*fold| if (fold.window_id == self.currentWindow().id) fold.closed = false;\n", "                for (self.folds.items) |*fold| {\n                    if (fold.window_id == self.currentWindow().id) fold.closed = false;\n                }\n"),
    ('    if (scope == .around) while (end < bytes.len and isSpaceByte(bytes[end])) end = nextCodepointStart(bytes, end);\n', '    if (scope == .around) {\n        while (end < bytes.len and isSpaceByte(bytes[end])) {\n            end = nextCodepointStart(bytes, end);\n        }\n    }\n'),
]

for old, new in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'expected exactly one match, got {count}: {old!r}')
    text = text.replace(old, new, 1)

path.write_text(text)
