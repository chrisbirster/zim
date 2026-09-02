# Zim Plugins

Zim v0.4.0 includes a built-in Git-backed package manager for in-process Lua plugins.

The design is intentionally small and native:

- plugin discovery and package state live in Zig
- plugin code runs in the embedded Lua 5.4 runtime
- plugins call the same public editor API used by `init.lua`
- installation/update/removal invokes `git` directly with argv; Zim does not construct shell commands
- every managed plugin is recorded at an exact Git commit SHA
- load order is deterministic
- a failing plugin does not prevent later plugins from loading
- failed plugin registrations are rolled back from commands, keymaps, and autocommands

Zim does **not** claim Neovim API or plugin compatibility.

## Plugin directory

Zim uses the same configuration root as `init.lua`.

Unix/macOS with XDG configuration:

```text
$XDG_CONFIG_HOME/zim/
```

Unix/macOS fallback:

```text
~/.config/zim/
```

Windows:

```text
%APPDATA%/zim/
```

Managed plugins are installed below:

```text
<config-root>/plugins/<plugin-name>/
```

The package lockfile lives at:

```text
<config-root>/plugins.lock
```

A typical layout is:

```text
~/.config/zim/
├── init.lua
├── plugins.lock
└── plugins/
    ├── git-signs/
    │   ├── zim-plugin.meta
    │   └── plugin.lua
    └── project-tools/
        ├── zim-plugin.meta
        └── lua/
            └── project_tools/
                └── init.lua
```

## Installing a plugin

Inside Zim:

```text
:PackAdd https://github.com/example/zim-plugin.git
```

To install a specific revision, tag, or commit:

```text
:PackAdd https://github.com/example/zim-plugin.git v1.2.0
```

`PackAdd` clones the repository, optionally checks out the requested revision in detached mode, reads the resulting Git `HEAD`, and writes that exact SHA to `plugins.lock`.

The new plugin is loaded on the next Zim startup. v0.4 intentionally does not hot-load newly cloned code into a running editor.

## Updating plugins

Update one plugin to the remote default branch:

```text
:PackUpdate zim-plugin
```

Update one plugin to an explicit revision:

```text
:PackUpdate zim-plugin 0123456789abcdef
```

Update every locked plugin:

```text
:PackUpdate
```

Each successful update replaces the lock entry with the exact resulting commit SHA. Restart Zim to reload updated plugin code.

## Removing a plugin

```text
:PackRemove zim-plugin
```

This removes the managed plugin directory and its lock entry. Restart Zim to unload code that was already loaded into the current process.

## Listing plugin state

```text
:PackList
```

`PackList` reports the known plugin state, including short commit revisions for locked plugins. Startup states are:

- `loaded` — manifest accepted and entry file executed successfully
- `failed` — the manifest or Lua entry failed
- `incompatible` — the plugin requested an unsupported API version, Zim version, or capability
- `installed` — installed during the current session and waiting for restart

When one or more plugins fail during startup, Zim reports a summary in the editor status. Use `:PackList` for per-plugin detail.

## Exact-SHA lockfile

The lockfile is a deliberately simple text format:

```text
# zim-plugin-lock-v1
plugin-name<TAB>source<TAB>exact-git-sha
```

Example:

```text
# zim-plugin-lock-v1
git-signs	https://github.com/example/git-signs.git	9f9d7ab10cbdf03f63aa090f212fe9be508abe71
```

Entries are written in deterministic name order. The revision column is the exact `HEAD` produced by installation or update, not a floating branch name.

## Plugin manifest

Every plugin directory must contain `zim-plugin.meta`.

Minimal manifest:

```text
name=git-signs
version=0.1.0
zim_api=1
```

Expanded manifest:

```text
name=git-signs
version=0.1.0
zim_api=1
min_zim=0.4.0
max_zim=0.6.0
entry=plugin.lua
capabilities=commands,keymaps,autocmds,buffers,lsp
```

Supported fields:

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | yes | Plugin name. Must match the installed directory name. |
| `version` | yes | Plugin version in `major.minor.patch` form. |
| `zim_api` | yes | Plugin API generation. v0.4 supports `1`. |
| `min_zim` | no | Minimum compatible Zim version. Defaults to the current v0.4 version. |
| `max_zim` | no | Maximum compatible Zim version. |
| `entry` | no | Lua entry file relative to the plugin root. Defaults to `plugin.lua`. |
| `capabilities` | no | Comma-separated declared capabilities. |

Unknown manifest keys are rejected so typos do not silently change compatibility behavior.

The entry path must be relative and cannot traverse upward with `..`.

## Capabilities

v0.4 recognizes these declarations:

- `commands`
- `keymaps`
- `autocmds`
- `buffers`
- `lsp`

Capabilities are compatibility metadata in v0.4, not a security sandbox. Lua plugins execute in-process and should be treated as trusted code.

## Writing a plugin

A minimal `plugin.lua` can use the public Lua API directly:

```lua
zim.command.create('HelloPlugin', function(args)
  zim.buf.set_text('hello from plugin: ' .. args)
end, {
  description = 'Replace the current buffer with a plugin greeting',
})

zim.keymap.set('normal', 'z', 'i')

zim.autocmd.create('BufWritePost', function(ev)
  -- ev.event, ev.sequence, ev.buffer, ev.window, ev.tab
end)
```

The complete Lua surface is documented in [Lua Configuration](LUA_CONFIGURATION.md).

## Lua modules and `require`

Before plugins load, Zim extends `package.path` with these patterns under the plugin root:

```text
plugins/?.lua
plugins/?/init.lua
plugins/?/lua/?.lua
plugins/?/lua/?/init.lua
```

That supports both a simple single-file plugin and a conventional module layout.

For example:

```text
plugins/project-tools/
├── zim-plugin.meta
├── plugin.lua
└── lua/
    └── project_tools/
        └── init.lua
```

`plugin.lua` can then use:

```lua
local tools = require('project_tools')
tools.setup()
```

## Deterministic startup

At startup Zim:

1. creates/opens the plugin directory
2. reads `plugins.lock`
3. registers the built-in package/discovery commands
4. configures Lua module search paths
5. discovers plugin directories
6. sorts plugin names lexicographically
7. validates each manifest
8. executes each compatible entry file in sorted order
9. loads the user's `init.lua`

This ordering makes plugin initialization reproducible and lets `init.lua` configure commands or behavior supplied by already-loaded plugins.

## Failure isolation

One broken plugin does not stop the remaining plugin set from loading.

If a plugin entry throws after registering commands, keymaps, or autocommands, Zim rolls those registrations back before continuing. The failed plugin remains visible through `:PackList` with diagnostic state.

Lua callbacks that fail later during normal editor operation continue to use the protected callback behavior introduced in v0.3; they report an editor status error instead of crashing Zim.

## Discovery

Use:

```text
:PackList
:Commands
:Keymaps
```

`Commands` lists the public command registry in deterministic name order. `Keymaps` lists the current public keymap registry. Together with `PackList`, these provide the initial v0.4 extension-discovery surface.

## Security model

Plugins are trusted in-process code. Installing a plugin gives its Lua code access to the Lua standard libraries exposed by Zim and to Zim's public Lua editor API.

The package manager avoids shell interpolation when invoking Git, validates plugin names, rejects unsafe entry paths, and caps file/process output reads, but these protections do not turn plugins into a sandbox.

Only install plugin repositories you trust.

## Deliberate v0.4 limits

v0.4 does not include:

- hot loading/unloading after package mutations
- a central plugin registry
- dependency resolution between plugins
- semantic-version constraint solving for package installation
- Neovim API compatibility
- Neovim plugin compatibility
- extmarks/plugin UI primitives
- asynchronous job/terminal APIs
- MessagePack-RPC remote plugins

Those capabilities belong to later roadmap milestones where appropriate.
