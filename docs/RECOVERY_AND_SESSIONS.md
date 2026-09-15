# Recovery and Sessions

Zim 1.0 treats editor state as recoverable data. The editor remains authoritative in Zig; persistence is an adapter around stable buffer/window/tab state.

## Last session

On a normal exit Zim atomically writes the last workspace session below the platform config root:

```text
state/session.json
```

When Zim starts without an explicit file or directory target, it attempts to restore that session. The snapshot includes:

- project root
- every open buffer, including unsaved text and modified state
- windows and their buffer bindings
- cursor and scroll positions
- tab pages
- split-layout topology
- active tab/window state

Pins are already persisted per project and are reloaded after the workspace session is restored.

Commands:

```text
:SessionSave
:SessionRestore
```

## Crash recovery

Crash recovery uses a separate atomic snapshot:

```text
state/recovery.json
```

Zim does **not** write the filesystem on every insert-mode keystroke. Instead it marks the recovery state dirty while typing and checkpoints at stable editing boundaries such as leaving insert mode, completing a normal-mode edit, leaving a buffer, or writing a buffer. The snapshot itself is written with atomic-replace semantics, so a partial write cannot replace the previous known-good recovery file.

After an abnormal exit, startup reports that recovery is available. Restore or discard it explicitly:

```text
:RecoveryRestore
:RecoveryDiscard
```

You can force a checkpoint at any time:

```text
:RecoveryWrite
```

A restored unsaved buffer remains marked modified. Recovery does not silently write source files.

## Failure behavior

A malformed or unsupported snapshot is validated before live editor collections are replaced. Restore failures are reported through the bounded Daily Driver error history and do not intentionally mutate the current workspace.

Use:

```text
:Errors
:Checkhealth
```

for the current session's recoverable-error and runtime summaries.
