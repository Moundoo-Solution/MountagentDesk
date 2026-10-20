import MountagentDeskKit
import SwiftUI

@main
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.current.apply()
        Notifier.requestAuthorization()
        #if DEBUG
        DebugHooks.run { [weak self] in self?.model }
        #endif
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stopAll()
        TerminalStore.shared.terminateAll()
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
