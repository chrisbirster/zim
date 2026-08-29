# Experiment: Agent Mode

**Status:** Tabled experiment

Zim is a terminal-only, Neovim-class editor. This document records an idea to explore later without changing the current implementation roadmap.

## Hypothesis

Agent interaction should feel like an editor mode rather than a separate chat application bolted onto the side of the editor.

Alongside Zim's traditional modal editing states, we may experiment with an **Agent mode** as a first-class mode:

```text
NORMAL
INSERT
VISUAL
AGENT
```

Agent mode would preserve the terminal-first editing experience while making coding agents part of the editor's interaction model.

## Possible interaction model

Entering Agent mode would make the current editor context available to an agent intentionally, including some combination of:

- current buffer and cursor/selection
- selected buffers or project files
- diagnostics and LSP information
- Tree-sitter syntax context
- Git diff/status
- explicit user instructions

The agent could then propose or perform work through Zim's editor/worktree APIs rather than acting as an unrelated chat surface.

Potential operations include:

- ask about the current selection or syntax node
- request an edit/refactor
- create or update a plan
- run tests or commands
- inspect a proposed diff
- accept/reject/apply agent changes
- manage an isolated branch/worktree

## Product inspiration

The experiment combines two earlier ideas:

- agent-first coding workflows such as T3 Code
- Cleartify's work/context model, where objectives, context, agent actions, diffs, tests, and review stay attached to the work rather than disappearing into chat history

The important difference is that Zim would keep the experience inside its terminal-native modal editor.

## Constraints

- Zim remains terminal-only.
- Agent mode must not require a graphical or web frontend.
- Normal editing must remain useful with no agent configured.
- Agents must not become part of the keystroke/render hot path outside Agent mode.
- Human review of agent-produced edits should be straightforward.
- Core editor primitives should not be distorted solely to support agents.

## Open questions

- What key enters/exits Agent mode?
- Is Agent mode primarily prompt entry, structured actions, or both?
- Does an agent edit the active buffer directly or work in an isolated branch/worktree by default?
- How should agent-generated edits interact with undo?
- Which context is sent automatically versus explicitly attached?
- Should plans, diffs, test output, and agent conversations be special Zim buffers?
- Can Tree-sitter/LSP context make agent requests more precise without sending unnecessary project data?

## Decision

Do not implement this yet. Finish the terminal editor foundation first, then prototype Agent mode once Zim has reliable buffers, modes, commands, Tree-sitter/LSP integration, Git/worktree primitives, and a usable review/diff experience.
