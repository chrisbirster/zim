from pathlib import Path

p = Path('src/tui.zig')
text = p.read_text()
old = '        "if (globalThis.__zimUiResize) globalThis.__zimUiResize({d}, {d});",'
new = '        "globalThis.__zimUiResize({d}, {d})",'
if old not in text:
    raise SystemExit('resize eval marker not found')
p.write_text(text.replace(old, new, 1))
