import MountagentDeskKit
import SwiftUI

/// ⌘T: an agent straight into a project, or into a branch of it in a worktree of its own,
/// with the first message on its way; or a terminal session running any command there.
struct QuickLaunch: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?
    /// Nil: a terminal session.
    @State private var agent: AgentKind? = .claude
    @State private var command = ""
    @State private var installed: [String] = []
    @State private var branch = ""
    @State private var message = ""
    @State private var branches: [String] = []
    @FocusState private var focused: Field?

    private enum Field { case branch, message, command }

    private var project: Project? { model.project(projectID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                Picker("Project", selection: $projectID) {
                    ForEach(model.projects) { project in
                        Text(project.name).tag(UUID?.some(project.id))
                    }
                }
                Picker("Agent", selection: $agent) {
                    ForEach(model.agentChoices) { kind in
                        Label(kind.displayName, systemImage: kind.symbolName).tag(AgentKind?.some(kind))
                    }
                    Divider()
                    Label("Terminal", systemImage: "terminal").tag(AgentKind?.none)
                }
                if agent == nil {
                    HStack(spacing: 6) {
                        TextField("Command", text: $command, prompt: Text("Empty: your shell"))
                            .font(.system(.body, design: .monospaced))
                            .focused($focused, equals: .command)
                        Menu {
                            ForEach(installed, id: \.self) { name in
                                Button(name) { command = name }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(installed.isEmpty)
                        .help("CLIs found on this Mac")
                    }
                }
                HStack(spacing: 6) {
                    TextField("Branch", text: $branch, prompt: Text("Empty: the main folder"))
                        .focused($focused, equals: .branch)
                    Menu {
                        ForEach(branches, id: \.self) { name in
                            Button(name) { branch = name }
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(branches.isEmpty)
                    .help("An existing branch")
                }
                if agent != nil {
                    TextField("First message", text: $message, prompt: Text("Optional"), axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused, equals: .message)
                }
                } header: {
                Text("Quick Launch")
                } footer: {
                    Text(footer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Launch") {
                    guard let project else { return }
                    model.quickLaunch(in: project, agent: agent ?? project.defaultAgent, branch: branch, message: message,
                                      command: agent == nil ? command : nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(project == nil)
            }
            .padding(16)
        }
        .frame(width: 520)
        .onAppear {
            let current = model.selectedSession
            projectID = current?.projectID ?? model.projects.first?.id
            if model.quickLaunchesTerminal {
                agent = nil
                model.quickLaunchesTerminal = false
                focused = .command
            } else {
                agent = current?.agent ?? project?.defaultAgent ?? model.agentChoices.first ?? .claude
                focused = .branch
            }
            #if DEBUG
            if let debugBranch = ProcessInfo.processInfo.environment["MOUNTAGENT_SHOW_QUICK_LAUNCH"], !debugBranch.isEmpty { branch = debugBranch }
            #endif
        }
        .task {
            installed = await Task.detached { TerminalCommands.installed() }.value
        }
        .task(id: projectID) {
            guard let url = project?.url else { return }
            branches = await Task.detached { GitWorktree.branches(in: url) }.value
        }
    }

    private var footer: String {
        let name = branch.trimmingCharacters(in: .whitespaces)
        let what = agent == nil ? "Runs \(command.trimmingCharacters(in: .whitespaces).isEmpty ? "your shell" : "the command")" : "Works"
        guard !name.isEmpty else { return "\(what) in \(project?.name ?? "the project")'s main folder." }
        let exists = branches.contains(name)
        return "Makes a worktree next to the repository, \(exists ? "on the existing branch" : "on a new branch from HEAD named") \(name), and \(agent == nil ? "runs there" : "works there")."
    }
}
