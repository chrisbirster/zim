# Jobs + Terminal

Zim v0.8.0 adds native asynchronous jobs and an interactive terminal without moving subprocess ownership into Hondo or Lua.

The design rule is simple: Zig owns process lifetime, pipes, PTYs, output buffering, terminal state, input, resize, and cancellation. Hondo only paints the resulting editor/terminal state.

## Asynchronous jobs

Jobs are for non-interactive tools such as builds, tests, formatters, generators, and scripts.

A job is started from an argv array. Zim does not implicitly invoke a shell for the public job API.

Each job has a stable numeric ID and one of these states:

- `running`
- `completed`
- `cancelled`
- `failed`

Standard output and standard error are captured independently. Both streams are visible while the job is running and are bounded so an untrusted or noisy child cannot consume unbounded editor memory. The default limit is 256 KiB per stream; snapshots report whether either stream was truncated.

Jobs may also specify a working directory, an explicit environment map through the Zig API, and piped or ignored stdin.

### Editor commands

Start a job:

```text
:JobStart zig build test
```

List known jobs and their current states:

```text
:JobList
```

Stop a running job:

```text
:JobStop 1
```

`JobStart` tokenizes the command-line text into argv values; it does not execute the text through a shell. Extensions that need exact argument boundaries should call the Zig or Lua API directly.

### Lua API

`zim.job` uses the same native job service as the built-in commands.

```lua
local id = zim.job.start({ 'zig', 'build', 'test' })
```

Optional settings currently include:

```lua
local id = zim.job.start({ 'my-tool', '--watch' }, {
  cwd = '/path/to/project',
  output_limit = 512 * 1024,
  stdin = 'pipe',
})
```

Inspect or stop it with:

```lua
local state = zim.job.status(id)
local stdout = zim.job.stdout(id)
local stderr = zim.job.stderr(id)
local stopped = zim.job.stop(id)
```

`stdout()` and `stderr()` return the output captured so far, including while a job is still running.

### Zig API

The public `Api` owns the job service and exposes start, wait, stop, status, snapshot, stdout, and stderr operations. `jobs.Options` carries the output limit, stdin policy, working directory, and optional environment map.

The job implementation is editor-independent: process execution and concurrent pipe draining live in `src/jobs.zig`; the public editor-facing service lives in `src/api/jobs.zig`.

## Interactive terminal

The terminal is a separate PTY-backed service intended for interactive shells and terminal applications.

Open the default shell:

```text
:terminal
```

Run a command in a terminal session:

```text
:terminal zig build test
```

Running `:terminal` again with no command reattaches the existing terminal session when one exists.

### Platform behavior

On Unix-like systems Zim uses a native `forkpty` boundary and launches the configured `$SHELL`, falling back to `/bin/sh`. A supplied `:terminal <command>` is passed to that shell with `-lc`.

On Windows Zim uses ConPTY. The shell comes from `%COMSPEC%`, falling back to `cmd.exe`. A supplied command is executed using the native `cmd.exe /d /s /c` convention.

The PTY abstraction keeps those platform details below the editor, Lua, and plugin surfaces.

### Terminal controls

While the terminal is visible:

- normal text input is UTF-8 encoded and sent directly to the PTY
- Enter, Backspace, Tab, Shift-Tab, and arrow keys are translated to terminal input
- `Ctrl-C` is sent to the child session instead of quitting Zim
- `Esc` hides the terminal and returns keyboard ownership to the editor
- editor/host terminal resizes are propagated to the child PTY

The terminal continues to run when its view is hidden and can be reattached with `:terminal`.

### Rendering and buffering

Zig owns the terminal screen model. It currently handles normal text flow, wrapping, carriage return, line feed, backspace, tab, scrolling, basic CSI cursor/erase commands, SGR control sequences, and OSC metadata sufficiently for the v0.8 terminal foundation.

Terminal output is bounded independently from jobs. The default terminal capture limit is 1 MiB; the terminal snapshot records whether output was truncated.

The Hondo layer does not parse terminal escape sequences or own subprocess state. It passively paints the native terminal screen into the existing cell grid and displays coarse session status.

## Plugin capability

Plugins that use `zim.job` may declare the `jobs` capability in `zim-plugin.meta`:

```text
name=build-tools
version=0.1.0
zim_api=1
min_zim=0.8.0
capabilities=commands,jobs
```

Capabilities remain compatibility metadata, not a security sandbox. Plugins execute as trusted in-process Lua code.

## Deliberate v0.8 scope

v0.8 establishes Zim-owned process and terminal primitives. It does not promise Neovim `jobstart()` / `termopen()` compatibility, a complete VT/xterm emulator, terminal multiplexing, or a plugin-owned terminal renderer.

Those can evolve later without changing the core ownership rule: subprocess and terminal state stay native to Zim.
