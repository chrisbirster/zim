from pathlib import Path

client_path = Path("src/lsp/client.zig")
client = client_path.read_text()
old_client = "        try self.beginInitialize(root_uri);\n"
new_client = "        _ = try self.beginInitialize(root_uri);\n"
if client.count(old_client) != 1:
    raise SystemExit(f"client initialize discard: expected 1 match, got {client.count(old_client)}")
client_path.write_text(client.replace(old_client, new_client, 1))

applicator_path = Path(".github/apply_lsp_editor.py")
applicator = applicator_path.read_text()
old_status = '        self.setStatus(if (forward) "next diagnostic" else "previous diagnostic", .{});\n'
new_status = '        if (forward) self.setStatus("next diagnostic", .{}) else self.setStatus("previous diagnostic", .{});\n'
if applicator.count(old_status) != 1:
    raise SystemExit(f"diagnostic status fix: expected 1 match, got {applicator.count(old_status)}")
applicator_path.write_text(applicator.replace(old_status, new_status, 1))
