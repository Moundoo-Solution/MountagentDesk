import MountagentDeskKit
import SwiftUI

/// ⌘T: an agent straight into a project, or into a branch of it in a worktree of its own,
/// with the first message on its way.
struct QuickLaunch: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: UUID?
    @State private var agent: AgentKind = .claude
    @State private var branch = ""
    @State private var message = ""
    @State private var branches: [String] = []
    @FocusState private var focused: Field?

    private enum Field { case branch, message }

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
                        Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
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
                TextField("First message", text: $message, prompt: Text("Optional"), axis: .vertical)
                    .lineLimit(3...8)
                    .focused($focused, equals: .message)
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
                    model.quickLaunch(in: project, agent: agent, branch: branch, message: message)
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
            agent = current?.agent ?? project?.defaultAgent ?? model.agentChoices.first ?? .claude
            focused = .branch
            #if DEBUG
            if let debugBranch = ProcessInfo.processInfo.environment["MOUNTAGENT_SHOW_QUICK_LAUNCH"], !debugBranch.isEmpty { branch = debugBranch }
            #endif
        }
        .task(id: projectID) {
            guard let url = project?.url else { return }
            branches = await Task.detached { GitWorktree.branches(in: url) }.value
        }
    }

    private var footer: String {
        let name = branch.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return "Works in \(project?.name ?? "the project")'s main folder." }
        let exists = branches.contains(name)
        return "Makes a worktree next to the repository, \(exists ? "on the existing branch" : "on a new branch from HEAD named") \(name), and works there."
    }
}
