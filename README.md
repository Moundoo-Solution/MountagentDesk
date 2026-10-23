<p align="center">
  <img src=".github/assets/icon.png" width="104" alt="Mountagent Desk icon" />
</p>

<h1 align="center">Every agent. One desk.</h1>

<p align="center">
  <img src="https://img.shields.io/badge/Claude_Code-D97757?logo=claude&logoColor=white" alt="Claude Code" />
  <img src="https://img.shields.io/badge/Codex-111111" alt="Codex" />
  <img src="https://img.shields.io/badge/Cursor-111111?logo=cursor&logoColor=white" alt="Cursor" />
  <img src="https://img.shields.io/badge/Copilot-111111?logo=githubcopilot&logoColor=white" alt="GitHub Copilot" />
  <img src="https://img.shields.io/badge/Antigravity-4285F4?logo=google&logoColor=white" alt="Antigravity" />
  <img src="https://img.shields.io/badge/Gemini_CLI-1A73E8?logo=googlegemini&logoColor=white" alt="Gemini CLI" />
  <img src="https://img.shields.io/badge/OpenCode-111111" alt="OpenCode" />
  <br />
  <sub>In their own terminal interface: Kiro · Amp · Kimi Code · Grok Build · Mistral Vibe · Droid · any CLI</sub>
</p>

<p align="center"><sub>🍎 Native macOS &nbsp;·&nbsp; 🆓 Free &nbsp;·&nbsp; 📖 MIT</sub></p>

<p align="center"><a href="#build"><b>Build it →</b></a></p>

![Two agents side by side in Mountagent Desk](.github/assets/hero.png)

<table>
  <tr>
    <td width="50%" valign="top"><h3>↩️ Undo any turn</h3><img src=".github/assets/revert.png" alt="A turn reverted, with Undo" /></td>
    <td width="50%" valign="top"><h3>🔎 ⌘K to any session</h3><img src=".github/assets/switcher.png" alt="The session switcher" /></td>
  </tr>
  <tr>
    <td valign="top"><h3>💬 Prompts on <code>/</code></h3><img src=".github/assets/prompts.png" alt="Saved prompts suggested in the composer" /></td>
    <td valign="top"><h3>🌿 A worktree per session</h3><img src=".github/assets/sessions.png" alt="Sessions, one in its own worktree, and an archive" /></td>
  </tr>
  <tr>
    <td valign="top"><h3>🖥️ Servers, read-only for agents</h3><img src=".github/assets/servers.png" alt="Servers with agent read access" /></td>
    <td valign="top"><h3>🔀 Git built in</h3><img src=".github/assets/git.png" alt="The Git workspace" /></td>
  </tr>
</table>

<p align="center">
  ✋ Approve commands &nbsp;·&nbsp; ⏳ Queue messages &nbsp;·&nbsp; 💵 Cost per project<br />
  🗂️ Archive &amp; export &nbsp;·&nbsp; 💾 Backup &amp; restore &nbsp;·&nbsp; 🎙️ Dictation
</p>

<a id="build"></a>

## 🛠️ Build

```sh
brew install xcodegen
scripts/make-signing-cert.sh   # once
scripts/build-app.sh           # installs /Applications/Mountagent Desk.app
```

<sub>macOS 14+ · Xcode 16+ · sign in to each agent CLI once · <a href="ARCHITECTURE.md">How it works</a> · <a href="LICENSE">MIT</a> · Copilot mark from <a href="https://github.com/primer/octicons">Primer Octicons</a> (MIT)</sub>
