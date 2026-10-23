import MountagentDeskKit
import SwiftUI

/// ⌘T: an agent straight into a project, or into a branch of it in a worktree of its own,
/// with the first message on its way; or a terminal session running any command there.
struct QuickLaunch: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?
    @State private var choice = Choice.agent(.claude)
    @State private var command = ""
    @State private var installed: [String] = []
    @State private var branch = ""
    @State private var message = ""
    @State private var branches: [String] = []
    @FocusState private var focused: Field?

    private enum Field { case branch, message, command }

    /// An agent, a terminal agent (Kiro, in its own interface), or any command.
    private enum Choice: Hashable {
        case agent(AgentKind)
        case terminalAgent(String)
        case terminal
    }

    private var agent: AgentKind? {
        if case .agent(let kind) = choice { kind } else { nil }
    }

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
                Picker("Agent", selection: $choice) {
                    ForEach(model.agentChoices) { kind in
                        Label(kind.displayName, systemImage: kind.symbolName).tag(Choice.agent(kind))
                    }
                    Divider()
                    ForEach(TerminalCommands.agents) { terminalAgent in
                        Label(terminalAgent.name, systemImage: terminalAgent.symbolName).tag(Choice.terminalAgent(terminalAgent.name))
                    }
                    Label("Terminal", systemImage: "terminal").tag(Choice.terminal)
                }
                if choice == .terminal {
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
                                      command: launchedCommand)
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
                choice = .terminal
                model.quickLaunchesTerminal = false
                focused = .command
            } else if let command = current?.command {
                choice = TerminalCommands.agent(for: command).map { .terminalAgent($0.name) } ?? .terminal
                focused = .branch
            } else {
                choice = .agent(current?.agent ?? project?.defaultAgent ?? model.agentChoices.first ?? .claude)
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

    /// The terminal session's command; nil for an agent.
    private var launchedCommand: String? {
        switch choice {
        case .agent: nil
        case .terminalAgent(let name): TerminalCommands.agents.first { $0.name == name }?.command
        case .terminal: command
        }
    }

    private var footer: String {
        let name = branch.trimmingCharacters(in: .whitespaces)
        let what = switch choice {
        case .agent: "Works"
        case .terminalAgent(let name):
            "Runs \(name) in its own terminal interface"
                + (TerminalCommands.agents.first { $0.name == name && ExecutableLocator.find($0.executable) == nil } != nil ? ", after its installer," : "")
        case .terminal: "Runs \(command.trimmingCharacters(in: .whitespaces).isEmpty ? "your shell" : "the command")"
        }
        guard !name.isEmpty else { return "\(what) in \(project?.name ?? "the project")'s main folder." }
        let exists = branches.contains(name)
        return "Makes a worktree next to the repository, \(exists ? "on the existing branch" : "on a new branch from HEAD named") \(name), and \(agent == nil ? "runs there" : "works there")."
    }
}
