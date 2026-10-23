import MountagentDeskKit
import SwiftUI
import UserNotifications

/// Starts the app, or, when an agent calls `mountagent-server`, runs that helper and exits
/// before any window or Dock icon appears.
@main
enum Launcher {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments.dropFirst()
        if arguments.first == ServerHelper.flag {
            exit(ServerHelper.run(Array(arguments.dropFirst())))
        }
        // Started by ssh as its askpass: the only argument is the prompt.
        if ProcessInfo.processInfo.environment[ServerPasswords.askpassVariable] != nil {
            exit(ServerHelper.run(Array(arguments)))
        }
        MountagentDeskApp.main()
    }
}

struct MountagentDeskApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Mountagent Desk", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { appDelegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    if let project = model.project(model.selectedSession?.projectID) ?? model.projects.first {
                        model.newSession(in: project)
                    }
                }
                .keyboardShortcut("n")
                .disabled(model.projects.isEmpty)

                Button("Add Project…") { model.chooseProjectFolder() }
                    .keyboardShortcut("o")
            }
            CommandGroup(replacing: .importExport) {
                Button("Back Up Data…") { DataBackup.backUp(model) }
                Button("Restore from Backup…") { DataBackup.restore(model) }
            }
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.control, .command])
                AppearanceMenu()
                Divider()
            }
            CommandMenu("Git") {
                GitCommands(model: model)
            }
            CommandMenu("Session") {
                Button("Go to Session…") { model.showsSwitcher = true }
                    .keyboardShortcut("k")
                    .disabled(model.sessions.isEmpty)
                Button("Quick Launch…") { model.showsQuickLaunch = true }
                    .keyboardShortcut("t")
                    .disabled(model.projects.isEmpty)
                Button("New Terminal Session…") {
                    model.quickLaunchesTerminal = true
                    model.showsQuickLaunch = true
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(model.projects.isEmpty)
                Divider()
                Button("Stop Agent") {
                    if let id = model.selectedSessionID { model.stop(id) }
                }
                .keyboardShortcut(".")
                .disabled(model.selectedSessionID.map(model.isRunning) != true)

                Button("Rules & Skills…") {
                    model.contextProject = model.project(model.selectedSession?.projectID)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model.selectedSession == nil)
            }
        }

        WindowGroup("Git", id: "git", for: String.self) { $root in
            if let root {
                GitWindow(root: root)
                    .environment(model)
            }
        }
        .defaultSize(width: 1300, height: 820)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.current.apply()
        UNUserNotificationCenter.current().delegate = self
        Notifier.requestAuthorization()
        #if DEBUG
        DebugHooks.run { [weak self] in self?.model }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Quitting (or closing the window) while agents work asks first: it stops them mid-turn.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let working = model?.running.count ?? 0
        guard working > 0 else { return .terminateNow }
        let question = NSAlert()
        question.messageText = working == 1 ? "An agent is still working" : "\(working) agents are still working"
        question.informativeText = "Quitting stops \(working == 1 ? "it" : "them") mid-turn. What \(working == 1 ? "it has" : "they have") done so far is kept in the session."
        question.addButton(withTitle: "Quit")
        question.addButton(withTitle: "Cancel")
        return question.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Shown in front too: the app only posts them for sessions you aren't looking at.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A click on a notification opens its session.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo[Notifier.sessionKey] as? String).flatMap(UUID.init(uuidString:))
        await MainActor.run { self.openSession(id) }
    }

    private func openSession(_ id: UUID?) {
        guard let id, let model, model.sessions[id] != nil else { return }
        model.selectedSessionID = id
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.interruptAll()
        model?.finishWrites()
        model?.stopHelperListener()
        TerminalStore.shared.terminateAll()
        ServerTerminals.shared.terminateAll()
        SessionTerminals.shared.terminateAll()
    }
}

/// Menu items that need `openWindow`, which only views can read.
private struct GitCommands: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Git") {
            if let root = model.defaultRepository { openWindow(id: "git", value: root) }
        }
        .keyboardShortcut("g", modifiers: [.command, .shift])
        .disabled(model.defaultRepository == nil)
    }
}
