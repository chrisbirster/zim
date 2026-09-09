# MessagePack-RPC + Remote Plugins

Zim v0.9 exposes the same native editor concepts used by built-ins and embedded Lua to trusted local external processes through MessagePack-RPC.

The important architectural rule is unchanged: **Zig owns editor state and the keystroke-to-render hot path.** RPC is an adapter over the public API, not a second editor implementation.

```text
built-ins ─────┐
embedded Lua ──┼──> public Zim API ──> native editor state
remote process ┘          ▲
        │                 │
        └─ MessagePack-RPC┘
```

Normal editing does not serialize through RPC. A remote callback only crosses the process boundary when the user explicitly registers one.

## Versions

v0.9.0 advertises:

```text
Zim version:       0.9.0
RPC protocol:      1
public API version: 1
```

A client should negotiate both RPC protocol and public API versions before using editor methods.

## Message framing

Zim uses the standard MessagePack-RPC array shapes:

```text
request       [0, msgid, method, params]
response      [1, msgid, error, result]
notification  [2, method, params]
```

`msgid` is an unsigned integer. `method` is a UTF-8 string. Request and notification `params` are arrays.

Responses use `nil` for `error` on success. Zim protocol/API errors are returned as error-name strings, for example:

```text
HandshakeRequired
ProtocolVersionMismatch
ApiVersionMismatch
UnknownRpcMethod
InvalidParams
```

## Handshake

Three methods are available before negotiation:

```text
zim.ping       []
zim.api_info   []
zim.handshake  [protocol_version, api_version]
```

`zim.ping` returns `"pong"`.

`zim.api_info` and a successful `zim.handshake` return metadata including:

```text
name
zim_version
protocol_version
api_version
callback_model
```

The callback model for v0.9 is `notifications`.

All other methods return `HandshakeRequired` until negotiation succeeds.

A normal v0.9 handshake is:

```text
[0, 1, "zim.handshake", [1, 1]]
```

## Capability discovery

After the handshake:

```text
zim.capabilities []
```

returns the RPC capabilities actually implemented by the current host. v0.9 advertises `buffers`, `commands`, `keymaps`, `autocmds`, `rpc.callbacks`, `rpc.stdio`, and `rpc.local`.

The native Zim API also has jobs, extmarks, diagnostics, and plugin UI primitives, but v0.9 does not advertise those over RPC because corresponding remote methods are not implemented yet.

Clients should prefer capability discovery over assuming that every future Zim build exposes every method.

## Buffer methods

Current buffer handle:

```text
zim.buffer.current []
```

Read text from the current buffer:

```text
zim.buffer.get_text []
```

or from a specific buffer handle:

```text
zim.buffer.get_text [buffer_id]
```

Replace the current buffer text:

```text
zim.buffer.set_text [text]
```

Buffer IDs are opaque public handles. Remote code must not treat them as pointers or infer internal object layout from them.

## Commands

Execute an existing public command:

```text
zim.command.execute [name]
zim.command.execute [name, args]
```

Register a command owned by the remote connection:

```text
zim.command.register [name, description, callback_id]
```

The result is a stable remote registration ID. When that command is invoked, Zim sends:

```text
[2, "zim.callback.command", [callback_id, name, args]]
```

The `callback_id` belongs to the remote process; the registration ID belongs to Zim and is used for cleanup/removal.

## Keymaps

Register a mapping through the same native keymap registry used by Zig and Lua:

```text
zim.keymap.set [mode, from_codepoint, to_codepoint, scope]
```

`mode` is a native mode name such as `normal` or `insert`. Codepoints are unsigned Unicode scalar values.

`scope` is:

```text
nil        global mapping
buffer_id  buffer-local mapping
```

The result is a remote registration ID.

The v0.9 mapping surface intentionally mirrors the current compact public keymap model: one Unicode codepoint maps to one Unicode codepoint. Rich key notation is future work.

## Autocommands

Register a callback:

```text
zim.autocmd.register [kind, callback_id, buffer_id_or_nil, once]
```

`kind` uses the native public event names such as `text_changed`, `buffer_enter`, or `buffer_write_post`.

When the event fires, Zim sends:

```text
[2, "zim.callback.autocmd", [
  callback_id,
  event_kind,
  sequence,
  buffer_id_or_nil,
  window_id_or_nil,
  tab_id_or_nil
]]
```

The event sequence is assigned by the native autocommand registry.

## Removing remote registrations

Commands, keymaps and autocommands registered by a remote connection can be removed with:

```text
zim.registration.remove [registration_id]
```

For diagnostics/testing:

```text
zim.registration.count []
```

All remaining remote registrations are cleaned up when that connection is discarded. Remote callbacks therefore cannot leave dangling native command/autocommand pointers after a client disconnects.

## stdio transport

For automation or a child-process plugin, run Zim headlessly over stdin/stdout:

```bash
zim --rpc-stdio
```

stdin and stdout become a raw concatenated MessagePack-RPC byte stream. Diagnostic/startup errors remain on stderr.

`--rpc-stdio` is headless even if `--headless` is omitted.

## Local IPC transport

For a process that attaches to a running Zim instance:

```bash
zim --rpc-listen <endpoint> .
```

The normal TUI remains active. Zim polls the local RPC endpoint from the editor thread, so RPC callbacks and editor mutations never race the editor from a background thread.

For a headless local server:

```bash
zim --headless --rpc-listen <endpoint>
```

### Linux and macOS

`<endpoint>` is a Unix-domain socket path, for example:

```bash
zim --rpc-listen /tmp/zim.sock .
```

### Windows

`<endpoint>` is a Windows named-pipe name. A short name is normalized into the local pipe namespace:

```powershell
zim --rpc-listen zim-main .
```

which corresponds to:

```text
\\.\pipe\zim-main
```

A fully qualified `\\.\pipe\...` name is also accepted.

## Connection lifecycle

v0.9 serves one remote client at a time per local endpoint.

Interactive Zim can accept another client after the prior client disconnects. Its remote registrations are discarded when the old connection is reset.

A headless `--rpc-listen` server exits after its first connected client disconnects. This makes it convenient for one-shot automation and integration tests.

## Security model

v0.9 RPC is **local only**:

- stdio
- Unix-domain sockets
- Windows named pipes

There is no TCP listener, network discovery, authentication protocol, TLS layer, or remote package registry in v0.9.

That local-only boundary reduces exposure; it is **not a sandbox**. A remote client that can connect can request supported editor mutations. Use endpoints accessible only to local processes you trust and rely on normal OS user/session permissions.

In-process Lua plugins remain trusted code as well. Package-managed Lua plugins and RPC remote plugins are two extension forms over the same conceptual public editor API, but they have different loading/lifecycle mechanisms.

## Deliberate v0.9 limits

v0.9 does not attempt to provide:

- Neovim API or plugin compatibility
- TCP/network RPC
- authentication or encryption above the local OS transport
- multiple simultaneous clients on one endpoint
- RPC methods for jobs, extmarks, diagnostics, or plugin UI yet
- remote callbacks on the normal keystroke/render path unless explicitly registered
- arbitrary pointer/internal-memory access
- a remote plugin marketplace or dependency solver
- a language-specific client SDK

The protocol is intentionally small enough that a client can be implemented directly with any MessagePack library.

## CI contract

The release gate runs the built Zim executable as an external process on Ubuntu, macOS, and Windows. It verifies:

- stdio MessagePack-RPC
- Unix-domain socket or Windows named-pipe RPC
- handshake-required diagnostics
- protocol-version mismatch diagnostics
- API-version mismatch diagnostics
- metadata/capability negotiation
- remote command registration
- command execution
- callback notification delivery

This process-boundary test sits on top of the native unit/integration suite; it does not replace the public API tests underneath it.
