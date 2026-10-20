# Architecture

```
App/ (SwiftUI, @MainActor)            Packages/MountagentDeskKit (no UI, unit-tested)
┌────────────────────────────┐        ┌──────────────────────────────────────────┐
│ Views ─ read ─▶ AppModel   │──────▶ │ AgentRunner ── Process ──▶ claude / cursor-agent
│ (Sidebar, Chat, Composer,  │        │   │ stdout lines                         │
│  Context, Settings)        │        │   ▼                                      │
│                            │ ◀───── │ AgentStreamParser (Claude | Cursor)      │
│ AppModel applies events    │ events │   → AgentEvent (normalised)              │
│ with TranscriptReducer     │        │ TranscriptReducer → ChatSession.items    │
│ and saves via ProjectStore │        │ ProjectStore (JSON in App Support)       │
└────────────────────────────┘        │ ProjectContext (rules, skills, MCP)      │
                                      └──────────────────────────────────────────┘
```

## Agents

- An `AgentProvider` builds the command line for one turn. A turn is one
  `-p --output-format stream-json` process:
  - Claude gets the prompt on stdin.
  - Cursor gets it as the last argument, because that CLI has no stdin prompt.
- An `AgentStreamParser` turns each JSON line into `AgentEvent`s. Only the parsers know
  either CLI's format.
  - Claude: `stream_event` deltas stream the text. The final `assistant` message then
    replaces the streamed text as a `textSnapshot`.
  - Cursor: deltas and whole-block snapshots arrive with the same shape. A message that
    starts with the text already streamed for the block is treated as a snapshot. The
    block resets at each tool call.
- `AgentRunner` reads stdout until EOF and then waits for the process to exit. That keeps
  the events in order: the stream always ends after the last line.
  - If the process exits without a `result` line, the runner emits `.failure` with the
    tail of stderr.
  - `cancel()` sends SIGINT, then SIGTERM after 3 s.
- `ExecutableLocator` merges the login shell's `PATH` with the usual install folders. Apps
  launched from Finder get a minimal `PATH`, so without this the CLIs wouldn't be found.

## Permissions

- **Claude** runs with `--input-format stream-json --permission-prompt-tool stdio`, and
  stdin stays open for the whole turn, as with the Agent SDK.
  - A `control_request` of subtype `can_use_tool` becomes `.permissionRequest`. The CLI
    blocks until `AgentRun.respond` writes the matching `control_response`.
  - "Always allow" sends back only the `addRules` suggestions as `updatedPermissions`.
    The CLI saves them to `.claude/settings.local.json`.
  - Any other control request is refused automatically, through `.reply`, so the CLI
    never hangs waiting for an answer.
  - Stdin is closed after `result`, which ends the process.
- **Cursor** can't ask anyone when it runs headless. A tool call with a `rejected` result
  becomes `.toolBlocked`, which carries a rule in `cli.json` form. `AppModel.retryBlocked`
  then:
  1. adds the rule to `.cursor/cli.json` (`CursorPermissions`)
  2. resumes the session with a follow-up message
  3. for "once", removes the rule again when that turn ends
- stdout is read with `availableData`, so events arrive as they are written. This
  matters for permission prompts: with buffered reads the app and the CLI would each wait
  for the other.

## Multi-folder projects

- A `Project` has a main folder (`path`) and additional folders (`additionalPaths`). The
  main folder is the working directory and holds the rules and skills that the editor
  manages.
- Both providers pass each additional folder as `--add-dir`.
- When `loadsAdditionalRules` is on:
  - `ClaudeProvider` sets `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`.
  - `CursorProvider` puts the folders' `AGENTS.md`/`CLAUDE.md` in front of the prompt, but
    only when the session isn't resumed. Without this, cursor-agent ignores rules in
    `--add-dir` folders (checked against cursor-agent 2026.10).
- Changing the main folder changes the CLIs' working directory, and they can't resume a
  session there. So the project's sessions drop their CLI session ids, and the next turn
  is handed over instead.

## Sessions and handoff

- `ChatSession` keeps two values per agent:
  - its CLI session id (`agentSessionIDs`), used for `--resume`
  - how many transcript items it had seen when its last turn ended (`seenCounts`)
- Before a turn, `unseenItems(for:)` returns the items that agent missed while the other
  agent was answering. `PromptBuilder` wraps the most recent 12k characters of them in
  `<previous_conversation>`. Because each agent resumes its own session, it is only told
  what it hasn't seen yet.

## Context files

`ProjectContext` edits files in place and has no format of its own:

- `AGENTS.md`: Cursor reads it directly. Claude reads it through `@AGENTS.md` in
  `CLAUDE.md`, and the editor offers to add that line when it's missing.
- `.claude/skills/*/SKILL.md`: both CLIs load these skills.
- Tool-specific rules stay in each tool's own folder: `.claude/rules/` and
  `.cursor/rules/`.

## Persistence

```
~/Library/Application Support/Mountagent Desk/projects.json
~/Library/Application Support/Mountagent Desk/sessions/<project>/<session>.json
```

- Files are written atomically.
- A session is saved when you send a message, when a turn ends, and when its settings
  change.
- Dates are stored as raw `Double` values, so a file decodes back to exactly what was
  saved.

## Invariants

- Views never parse CLI output. Parsers never touch the UI.
- `MountagentDeskKit` has no AppKit or SwiftUI imports, so `swift test` covers it without
  launching the app.
- Each CLI's stream format is pinned by the recorded fixtures. When a CLI changes its
  format, record a new fixture and update the parser together with it.
