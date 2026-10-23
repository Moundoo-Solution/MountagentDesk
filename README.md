<p align="center">
  <img src=".github/assets/icon.png" width="112" alt="Mountagent Desk icon" />
</p>

<h1 align="center">Every agent. One desk.</h1>

<p align="center">
  <b>Claude Code</b> · <b>Codex</b> · <b>Cursor</b> · <b>Copilot</b> · <b>Antigravity</b><br />
  <sub>A native Mac app for the coding agents you already use. Free and open source.</sub>
</p>

<p align="center">
  <a href="#build"><b>Build it →</b></a> &nbsp;·&nbsp; <a href="ARCHITECTURE.md">How it works</a>
</p>

![Two agents working side by side in Mountagent Desk](.github/assets/panes.png)

### `01 / 04`&nbsp; Run.

**Up to four agents side by side.** Switch agent mid-session; the next one picks up where the last left off.

### `02 / 04`&nbsp; Approve.

**Commands wait for you.** Allow once, always, or deny. Write the next message while the agent works.

### `03 / 04`&nbsp; Undo.

**Every turn is a checkpoint.** Revert a turn in one click. Give a session its own worktree so agents never collide.

![The Git workspace: changes, diff and commit](.github/assets/git.png)

### `04 / 04`&nbsp; Reach.

**Servers, read-only for agents.** SSH terminals for you. Logs and `SELECT`s for agents, nothing that writes.

<table>
  <tr>
    <td align="center"><b>⌘K</b><br /><sub>Find any session</sub></td>
    <td align="center"><b>/</b><br /><sub>Saved prompts</sub></td>
    <td align="center"><b>$</b><br /><sub>Cost per project</sub></td>
    <td align="center"><b>⇪</b><br /><sub>Backup and restore</sub></td>
  </tr>
</table>

## Build

```sh
brew install xcodegen
scripts/make-signing-cert.sh   # once
scripts/build-app.sh           # installs /Applications/Mountagent Desk.app
```

<sub>macOS 14+ and Xcode 16+. Sign in to each agent CLI once in Terminal. Tests: `cd Packages/MountagentDeskKit && swift test`. Coming from AgentDesk? Your data moves over on first launch.</sub>

## License

[MIT](LICENSE). The Copilot mark is from [Primer Octicons](https://github.com/primer/octicons), © GitHub Inc., MIT License.
