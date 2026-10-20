# Working on Mountagent Desk

A macOS SwiftUI app (`App/`) on top of a UI-free Swift package (`Packages/MountagentDeskKit`).
`ARCHITECTURE.md` explains how the pieces fit.

## Commands

- Core tests: `cd Packages/MountagentDeskKit && swift test`
- Live CLI tests, which need both CLIs signed in: `MOUNTAGENT_LIVE=1 swift test --filter LiveAgentTests`
- App build: `scripts/build-app.sh`, or `CONFIGURATION=Debug scripts/build-app.sh`
- Xcode project: `xcodegen generate`. Never commit `MountagentDesk.xcodeproj`.

## Rules

- Swift 6 with strict concurrency. `AppModel` and the views are `@MainActor`; the Kit
  types are `Sendable`.
- Keep CLI-specific knowledge inside `ClaudeProvider` and `CursorProvider`. To support a
  new agent:
  1. Add an `AgentKind` case.
  2. Write a provider and a parser for it.
  3. Record a fixture of its real output and add a replay test.
- If a parser change alters behaviour, back it with a fixture recorded from the real CLI,
  not a hand-written one.
- Leave the App Sandbox off. The app has to launch CLIs and open any folder.
