from pathlib import Path


def replace(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"marker not found in {path}: {old!r}")
    p.write_text(text.replace(old, new, 1))


replace(
    "src/tui.zig",
    '        "globalThis.__zimUiResize?.({d}, {d});",',
    '        "if (globalThis.__zimUiResize) globalThis.__zimUiResize({d}, {d});",',
)
replace(
    "src/editor_view.zig",
    "    _ = props_json;\n    const editor = bound_editor orelse return error.EditorViewUnbound;",
    "    _ = context;\n    _ = props_json;\n    const editor = bound_editor orelse return error.EditorViewUnbound;",
)
replace(
    "src/editor_view.zig",
    "    state.* = .{ .editor = editor };\n    try publishState(state, context);\n    return state;",
    "    state.* = .{ .editor = editor };\n    return state;",
)
