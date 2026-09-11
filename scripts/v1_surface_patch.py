#!/usr/bin/env python3
"""Temporary assertion-driven transform for the final v1 surface patch.

This script is intentionally branch-only and is removed once the pinned Zig
formatter has validated the resulting sources.
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def replace_exact(path: str, old: str, new: str, expected: int = 1) -> None:
    target = ROOT / path
    text = target.read_text()
    count = text.count(old)
    if count != expected:
        raise SystemExit(f"{path}: expected {expected} occurrences, found {count}: {old!r}")
    target.write_text(text.replace(old, new))


# Coherent 1.0.0 product/version reporting across every public extension surface.
replace_exact("src/plugin_manager.zig", 'pub const zim_version = "0.9.0";', 'pub const zim_version = "1.0.0";')
replace_exact("src/rpc/host.zig", 'pub const zim_version = "0.9.0";', 'pub const zim_version = "1.0.0";')
replace_exact("src/lua_runtime.zig", '_ = self.lua.pushString("0.7.0");', '_ = self.lua.pushString("1.0.0");')
replace_exact("scripts/rpc-smoke.py", 'Process-boundary smoke test for Zim v0.9 MessagePack-RPC.', 'Process-boundary smoke test for Zim v1.0 MessagePack-RPC.')
replace_exact("scripts/rpc-smoke.py", 'EXPECTED_ZIM_VERSION = "0.9.0"', 'EXPECTED_ZIM_VERSION = "1.0.0"')

# Renderer consumes the native v1 highlight registry. Keep existing hard-coded
# styles as fallbacks so rendering remains safe if no Daily Driver store exists.
replace_exact(
    "src/editor_view.zig",
    'const editor_module = @import("editor.zig");\n',
    'const editor_module = @import("editor.zig");\nconst theme_module = @import("theme.zig");\n',
)
replace_exact(
    "src/editor_view.zig",
    '''            try grid.paintUtf8Styled(bounds.x, bounds.y + row, number, gutter, .{\n                .foreground = if (current_line) .{ .ansi = 13 } else .{ .ansi = 8 },\n                .attributes = .{ .dim = !current_line },\n            });''',
    '''            const line_style = if (current_line)\n                themedStyle("CursorLineNr", .{ .foreground = .{ .ansi = 13 } })\n            else\n                themedStyle("LineNr", .{ .foreground = .{ .ansi = 8 }, .attributes = .{ .dim = true } });\n            try grid.paintUtf8Styled(bounds.x, bounds.y + row, number, gutter, line_style);''',
)
replace_exact(
    "src/editor_view.zig",
    '''                    try grid.paintUtf8Styled(content_x + used + 1, y, annotation, content_width - used - 1, .{ .foreground = .{ .ansi = 8 }, .attributes = .{ .italic = true, .dim = true } });''',
    '''                    try grid.paintUtf8Styled(\n                        content_x + used + 1,\n                        y,\n                        annotation,\n                        content_width - used - 1,\n                        themedStyle("VirtualText", .{ .foreground = .{ .ansi = 8 }, .attributes = .{ .italic = true, .dim = true } }),\n                    );''',
)
replace_exact(
    "src/editor_view.zig",
    '''fn extmarkStyle(name: ?[]const u8) @TypeOf((hondo.cell_grid.Cell{}).style) {\n    const value = name orelse return .{ .foreground = .{ .ansi = 13 } };\n    if (std.mem.eql(u8, value, "DiagnosticError")) return .{ .foreground = .{ .ansi = 9 }, .attributes = .{ .bold = true } };\n    if (std.mem.eql(u8, value, "DiagnosticWarn")) return .{ .foreground = .{ .ansi = 11 }, .attributes = .{ .bold = true } };\n    if (std.mem.eql(u8, value, "DiagnosticInfo")) return .{ .foreground = .{ .ansi = 14 } };\n    if (std.mem.eql(u8, value, "DiagnosticHint")) return .{ .foreground = .{ .ansi = 8 }, .attributes = .{ .italic = true } };\n    return .{ .foreground = .{ .ansi = 13 } };\n}\n\nfn syntaxStyle(capture: []const u8) @TypeOf((hondo.cell_grid.Cell{}).style) {\n    if (std.mem.indexOf(u8, capture, "comment") != null) return .{\n        .foreground = .{ .ansi = 8 },\n        .attributes = .{ .italic = true },\n    };\n    if (std.mem.indexOf(u8, capture, "string") != null) return .{ .foreground = .{ .ansi = 10 } };\n    if (std.mem.indexOf(u8, capture, "keyword") != null) return .{\n        .foreground = .{ .ansi = 13 },\n        .attributes = .{ .bold = true },\n    };\n    if (std.mem.indexOf(u8, capture, "function") != null) return .{ .foreground = .{ .ansi = 14 } };\n    if (std.mem.indexOf(u8, capture, "type") != null) return .{ .foreground = .{ .ansi = 12 } };\n    if (std.mem.indexOf(u8, capture, "number") != null or std.mem.indexOf(u8, capture, "constant") != null) {\n        return .{ .foreground = .{ .ansi = 11 } };\n    }\n    if (std.mem.indexOf(u8, capture, "operator") != null) return .{ .foreground = .{ .ansi = 6 } };\n    return .{};\n}\n''',
    '''fn extmarkStyle(name: ?[]const u8) @TypeOf((hondo.cell_grid.Cell{}).style) {\n    const value = name orelse return themedStyle("PluginAccent", .{ .foreground = .{ .ansi = 13 } });\n    if (theme_module.activeStyle(value) != null) return themedStyle(value, .{});\n    if (std.mem.eql(u8, value, "DiagnosticError")) return .{ .foreground = .{ .ansi = 9 }, .attributes = .{ .bold = true } };\n    if (std.mem.eql(u8, value, "DiagnosticWarn")) return .{ .foreground = .{ .ansi = 11 }, .attributes = .{ .bold = true } };\n    if (std.mem.eql(u8, value, "DiagnosticInfo")) return .{ .foreground = .{ .ansi = 14 } };\n    if (std.mem.eql(u8, value, "DiagnosticHint")) return .{ .foreground = .{ .ansi = 8 }, .attributes = .{ .italic = true } };\n    return themedStyle("PluginAccent", .{ .foreground = .{ .ansi = 13 } });\n}\n\nfn syntaxStyle(capture: []const u8) @TypeOf((hondo.cell_grid.Cell{}).style) {\n    const fallback: @TypeOf((hondo.cell_grid.Cell{}).style) = if (std.mem.indexOf(u8, capture, "comment") != null)\n        .{ .foreground = .{ .ansi = 8 }, .attributes = .{ .italic = true } }\n    else if (std.mem.indexOf(u8, capture, "string") != null)\n        .{ .foreground = .{ .ansi = 10 } }\n    else if (std.mem.indexOf(u8, capture, "keyword") != null)\n        .{ .foreground = .{ .ansi = 13 }, .attributes = .{ .bold = true } }\n    else if (std.mem.indexOf(u8, capture, "function") != null)\n        .{ .foreground = .{ .ansi = 14 } }\n    else if (std.mem.indexOf(u8, capture, "type") != null)\n        .{ .foreground = .{ .ansi = 12 } }\n    else if (std.mem.indexOf(u8, capture, "number") != null or std.mem.indexOf(u8, capture, "constant") != null)\n        .{ .foreground = .{ .ansi = 11 } }\n    else if (std.mem.indexOf(u8, capture, "operator") != null)\n        .{ .foreground = .{ .ansi = 6 } }\n    else\n        .{};\n    const group = theme_module.groupForCapture(capture) orelse return fallback;\n    return themedStyle(group, fallback);\n}\n\nfn themedStyle(\n    group: []const u8,\n    fallback: @TypeOf((hondo.cell_grid.Cell{}).style),\n) @TypeOf((hondo.cell_grid.Cell{}).style) {\n    const source = theme_module.activeStyle(group) orelse return fallback;\n    var result: @TypeOf((hondo.cell_grid.Cell{}).style) = .{};\n    if (source.foreground) |foreground| result.foreground = .{ .ansi = @intCast(foreground) };\n    if (source.background) |background| result.background = .{ .ansi = @intCast(background) };\n    result.attributes.bold = source.bold;\n    result.attributes.italic = source.italic;\n    result.attributes.dim = source.dim;\n    result.attributes.underline = source.underline;\n    return result;\n}\n''',
)

# Prove that renderer style lookup really follows the active native theme.
needle = '''test "split layout paints two native editor windows with a divider" {'''
addition = '''test "native renderer styles follow the active v1 theme registry" {\n    var store = theme_module.Store.init(std.testing.allocator);\n    defer store.deinit();\n    try store.load("zim");\n    theme_module.activate(&store);\n    defer theme_module.deactivate(&store);\n\n    try store.set("Keyword", .{ .foreground = 2, .italic = true });\n    const style = syntaxStyle("keyword.function");\n    try std.testing.expect(style.foreground.eql(.{ .ansi = 2 }));\n    try std.testing.expect(style.attributes.italic);\n}\n\n'''
replace_exact("src/editor_view.zig", needle, addition + needle)

print("v1 surface patch applied")
