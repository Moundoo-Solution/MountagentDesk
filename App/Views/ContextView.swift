import MountagentDeskKit
import SwiftUI

/// Edits a project's rules, skills and MCP config in place.
struct ContextView: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project
    private var context: ProjectContext { ProjectContext(root: project.url) }

    @State private var files: [ProjectContext.File] = []
    @State private var skills: [ProjectContext.Skill] = []
    @State private var claudeReadsAgents = true
    @State private var selection: String?
    @State private var draft = ""
    @State private var saved = ""
    @State private var error: String?

    @State private var creatingSkill = false
    @State private var creatingRule: ProjectContext.RuleTarget?
    @State private var newName = ""
    @State private var newDescription = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(ProjectContext.Group.allCases) { group in
                    let groupFiles = files.filter { $0.group == group }
                    if !groupFiles.isEmpty {
                        Section(group.rawValue) {
                            ForEach(groupFiles) { file in
                                Label {
                                    Text(file.relativePath)
                                        .italic(!file.exists)
                                        .foregroundStyle(file.exists ? .primary : .secondary)
                                } icon: {
                                    Image(systemName: file.exists ? "doc.text" : "doc.badge.plus")
                                }
                                .tag(file.relativePath)
                            }
                        }
                    }
                }
                Section("Skills · Claude and Cursor") {
                    ForEach(skills) { skill in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(skill.name, systemImage: "wand.and.stars")
                            if !skill.description.isEmpty {
                                Text(skill.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .tag(skill.relativePath)
                        .contextMenu {
                            Button("Delete Skill", role: .destructive) { deleteSkill(skill) }
                        }
                    }
                    if skills.isEmpty {
                        Text("No skills yet").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Menu {
                        Button("Skill (Claude and Cursor)…") { newName = ""; newDescription = ""; creatingSkill = true }
                        Divider()
                        ForEach(ProjectContext.RuleTarget.allCases) { target in
                            Button(target == .claude ? "Claude rule…" : "Cursor rule…") { newName = ""; creatingRule = target }
                        }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .fixedSize()
                    Spacer()
                }
                .padding(10)
            }
        } detail: {
            VStack(spacing: 0) {
                if !claudeReadsAgents {
                    HStack {
                        Image(systemName: "link")
                        Text("Claude doesn't read AGENTS.md yet. Cursor does.")
                        Spacer()
                        Button("Add @AGENTS.md to CLAUDE.md") { linkClaude() }
                    }
                    .font(.callout)
                    .padding(10)
                    .background(.yellow.opacity(0.15))
                }
                if let selection {
                    editor(for: selection)
                } else {
                    ContentUnavailableView("Pick a file", systemImage: "doc.text", description: Text("Rules tell the agents how to work in \(project.name). Skills are step-by-step guides they load when a task matches the description."))
                }
            }
        }
        .frame(minWidth: 900, minHeight: 580)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: selection) { open(selection) }
        .alert("New skill", isPresented: $creatingSkill) {
            TextField("Name", text: $newName)
            TextField("When should the agent use it?", text: $newDescription)
            Button("Create", action: createSkill)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved to .claude/skills/, which Claude Code and Cursor both read.")
        }
        .alert("New rule", isPresented: Binding(get: { creatingRule != nil }, set: { if !$0 { creatingRule = nil } })) {
            TextField("Name", text: $newName)
            Button("Create") { if let target = creatingRule { createRule(target) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Couldn't save", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func editor(for path: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(path).font(.headline.monospaced())
                if draft != saved { Text("Edited").font(.caption).foregroundStyle(.orange) }
                Spacer()
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([context.url(path)]) }
                    .disabled(!FileManager.default.fileExists(atPath: context.url(path).path))
                Button("Revert") { draft = saved }
                    .disabled(draft == saved)
                Button("Save") { save(path) }
                    .keyboardShortcut("s")
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == saved && FileManager.default.fileExists(atPath: context.url(path).path))
            }
            .padding(10)
            Divider()
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
        }
    }

    private func reload() {
        files = context.files()
        skills = context.skills()
        claudeReadsAgents = context.claudeReadsAgentsFile
        if selection == nil { selection = "AGENTS.md" }
    }

    private func open(_ path: String?) {
        guard let path else { return }
        let exists = FileManager.default.fileExists(atPath: context.url(path).path)
        saved = exists ? context.read(path) : ""
        draft = exists ? saved : context.template(for: path)
    }

    private func save(_ path: String) {
        do {
            try context.write(draft, to: path)
            saved = draft
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func linkClaude() {
        do {
            try context.linkAgentsFileToClaude()
            reload()
            if selection == "CLAUDE.md" { open("CLAUDE.md") }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createSkill() {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        do {
            let skill = try context.createSkill(name: newName, description: newDescription)
            reload()
            selection = skill.relativePath
        } catch {
            self.error = "A skill with that name already exists, or the folder isn't writable."
        }
    }

    private func createRule(_ target: ProjectContext.RuleTarget) {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let path = context.newRulePath(named: newName, for: target)
        do {
            if !FileManager.default.fileExists(atPath: context.url(path).path) {
                try context.write(context.template(for: path), to: path)
            }
            reload()
            selection = path
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func deleteSkill(_ skill: ProjectContext.Skill) {
        do {
            try context.deleteSkill(skill)
            if selection == skill.relativePath { selection = nil }
            reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
