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
- **Copilot** can't ask either. Without `--allow-all-tools` it still runs reads and
  read-only commands, and refuses the rest with a `denied` error. That error becomes
  `.toolBlocked` (no rule), and the retry runs with full access.
  - Refusals by a `--deny-tool` rule (the servers' ssh rules) mention "following rules"
    and get no retry.
  - Copilot signs in with `COPILOT_GITHUB_TOKEN`: the `gh` token of the account picked in
    Settings → Agents. It is passed per turn and kept out of Copilot's shell through
    `--secret-env-vars`.
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

## Servers

- A `Server` (in `servers.json`) is linked to projects through `Project.serverIDs`, like
  git accounts.
- A server signs in with a shared `ServerCredential` (`server-credentials.json`): a user
  with a key, a password, or both, like an entry in Termius's keychain. `SSHLogin` combines
  the two into ssh command lines.
- The Servers panel opens `ssh` in SwiftTerm tabs (`ServerTerminals`). A server whose name
  says live or prod asks before connecting and shows a red frame.
- Agents never get to a server on their own:
  - Claude runs with `--disallowedTools` rules for ssh, scp, sftp and rsync, also when
    called by path or through `env`/`command`/`exec`/`nohup` (`ServerHelper.claudeDenyRules`);
    Copilot gets `--deny-tool` rules for the names and full paths. Deny rules hold even with
    full access.
  - With agent access on, the turn's prompt names the readable servers, and
    `bin/mountagent-server` (written at launch) is put first on PATH. The script runs the
    app's own executable with `--server-exec`, which `Launcher` hands to `ServerHelper`
    before any UI starts. The helper decides nothing: it sends the run's token
    (`MOUNTAGENT_HELPER_TOKEN`, issued for one turn and revoked when it ends), the server
    and the command to the running app over a 0600 Unix socket (`ServerBroker`,
    `helper.sock` in the data folder).
  - The app looks up the project from the token, checks the server is linked and has agent
    access, and `ServerCommandPolicy` checks that the command only reads. Every call, run or
    refused, goes to `server-audit.log`. Agent access lives in the keychain
    (`ServerPasswords.agentAccess`); servers.json only mirrors it, so editing the file grants
    nothing.
  - The app runs ssh itself (`ServerRun`) in a pseudo-terminal of its own, with
    `-F /dev/null` (no ProxyCommand, LocalCommand or `Match exec` from ~/.ssh/config; an
    alias's host name, user, port and key are parsed by the app), `StrictHostKeyChecking=yes`
    and stdin closed. A saved password is typed at ssh's own prompt, never handed out
    through askpass; the command's output comes back on a separate pipe, so nothing the
    server prints can pass for that prompt. A one-time-code prompt stops the call with a
    message. Commands stop after 60 s and 1 MB of output.
  - `psql` takes only `-c`, `-d`, `-U`, `-h`, `-p`, `-A`, `-t`, `-x`, `-q`, `-X`, `-w`, `-F`,
    `-R` and `-l` (clusters such as `-qAtc` are read letter by letter), and its queries get
    `SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY` sent first. Long options of the
    other programs are matched in every shortened form (`--out` is `--output`).
  - `sudo` is refused unless the server's settings list users agents may `sudo -u` to
    (`root` for plain sudo); that list lives in the keychain too. `docker inspect` needs a
    `--format` over harmless fields, `systemctl show`/`cat` and `ps e…` are refused: they
    print services' and processes' environments.
  - `MOUNTAGENT_DATA_DIR` is honoured by debug builds only.
- Passwords live in the login keychain (`ServerPasswords`: this device only, never in
  JSON). A server may have its own (`passwordSaved`), which wins over its credential's. For
  the user's own terminals and connection tests, ssh reads them through `SSH_ASKPASS` = the
  app's own executable (not the script in the data folder, which agents can write), which
  answers only when its parent is `/usr/bin/ssh` and ssh's parent is the app. Other prompts (an authenticator code, a key
  passphrase) are asked on the terminal ssh runs in; connection tests have none, so they get
  the reason instead. Picked key files (`.pem`) are copied to `~/.ssh/mountagent/` with
  mode 600.
- The policy is a guard rail, not a sandbox: Cursor and Codex have no deny rule for ssh.
  The real guarantee is a read-only SSH user and database role on the server.

## Persistence

```
~/Library/Application Support/Mountagent Desk/projects.json
~/Library/Application Support/Mountagent Desk/sessions/<project>/<session>.json
```

- Files are written atomically, as compact JSON. Sessions are saved on a background
  queue, in order (`ProjectStore.saveLater`); quitting waits for it (`finishWrites`).
- A session is saved when you send a message, when a turn ends, and when its settings
  change.
- Dates are stored as raw `Double` values, so a file decodes back to exactly what was
  saved.
- A file that no longer decodes is set aside as `*.corrupt-<date>` and reported, never
  skipped silently or overwritten (projects.json is copied before the next save). One
  unreadable row (a newer kind) drops alone; the rest of its session loads.
- Deleted sessions and removed projects' sessions go to the Trash, after a confirmation.
- At launch, sessions are decoded in parallel; tool rows still marked running (the app
  quit mid-turn) become failed.
- File ▸ Back Up Data zips the folder and the app's settings (not the keychain);
  Restore keeps today's data next to it, then relaunches.

## Turns

- Streamed text and thinking are applied in batches every 80 ms (`TurnBuffer`); other
  events (tools, questions, the end) at once. So a long reply redraws the views a dozen
  times a second, not once per token.
- Before each turn the working folder is checkpointed (`GitCheckpoint`): a commit of all
  files, tracked or not (ignored ones aside), built in a copy of the index and kept under
  `refs/mountagent/checkpoints/<session>/<turn>` (60 per repository). The user's files,
  index and branches aren't touched. "Revert this turn" puts the files back, removes the
  ones the turn added, and keeps the state before as another checkpoint, which the notice's
  Undo restores. Commits made in the turn stay.
- A message sent while the agent works waits (`AppModel.queued`) and goes when the turn
  ends. Quitting with agents at work asks first; their sessions keep the partial turn and a
  notice. Drafts are kept per session while switching.
- A session may have its own worktree (`GitWorktree`): a branch `mountagent/…` and a
  working copy in `<repository>.worktrees/`, where its agents run and its checkpoints
  are taken. Removing it keeps the branch.
- Usage is recorded per agent and per project (`UsageLedger`), for the project menu and a
  CSV export.
- Every git command the app runs goes through `GitSafety`: agents can edit `.git/config`
  and `.gitattributes`, and the app runs git in their repositories by itself (checkpoints,
  the Git window's status), so fsmonitor is off, filters defined in the repository's own
  config are emptied (the user's own and the standard LFS setup are kept), diff, log,
  show and blame run without external diff or textconv, and the app's bookkeeping
  (checkpoints, worktrees) runs no hooks. A repository whose config sets a long-running
  `process` filter is refused until it's removed. Restoring a checkpoint never removes
  files outside the repository.

## Invariants

- Views never parse CLI output. Parsers never touch the UI.
- `MountagentDeskKit` has no AppKit or SwiftUI imports, so `swift test` covers it without
  launching the app.
- Each CLI's stream format is pinned by the recorded fixtures. When a CLI changes its
  format, record a new fixture and update the parser together with it.
