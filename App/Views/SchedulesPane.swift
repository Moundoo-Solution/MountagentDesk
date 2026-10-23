import MountagentDeskKit
import SwiftUI

/// Settings → Schedules: each scheduled prompt with its timing, last and next run.
struct SchedulesPane: View {
    @Environment(AppModel.self) private var model
    @State private var editing: ScheduledTask?

    var body: some View {
        SettingsSection(title: "Scheduled tasks", footer: "Each run opens a new session in the project; it shows up in the sidebar with a dot and a notification when it ends. Read only is the safe choice for runs nobody watches.") {
            if model.scheduledTasks.isEmpty {
                SettingsRow(title: "No schedules yet", detail: "For example: every weekday at 9:00, run the tests and report what fails.", divider: false) {
                    EmptyView()
                }
            }
            ForEach(Array(model.scheduledTasks.enumerated()), id: \.element.id) { index, task in
                SettingsRow(title: task.name, detail: detail(task), divider: index > 0) {
                    HStack(spacing: 8) {
                        Button("Run Now") { model.runScheduledTask(task.id) }
                            .controlSize(.small)
                        Button("Edit…") { editing = task }
                            .controlSize(.small)
                        Toggle("On", isOn: Binding(get: { task.enabled }, set: { on in
                            var changed = task
                            changed.enabled = on
                            // Turned back on: count from now, not from a run long past.
                            if on { changed.lastRun = .now }
                            model.saveScheduledTask(changed)
                        }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
            }
        }
        HStack {
            Spacer()
            Button {
                guard let project = model.project(model.selectedSession?.projectID) ?? model.projects.first else { return }
                editing = ScheduledTask(name: "", projectID: project.id, agent: project.defaultAgent, prompt: "")
            } label: {
                Label("Add Schedule…", systemImage: "plus")
            }
            .disabled(model.projects.isEmpty)
        }
        .sheet(item: $editing) { task in
            ScheduleEditor(task: task, isNew: !model.scheduledTasks.contains { $0.id == task.id })
        }
    }

    private func detail(_ task: ScheduledTask) -> String {
        var parts = [task.scheduleDescription(), model.project(task.projectID)?.name ?? "missing project", task.agent.displayName]
        if task.enabled {
            parts.append("next " + task.nextRun().formatted(date: .abbreviated, time: .shortened))
        } else {
            parts.append("off")
        }
        if let last = task.lastRun, last != task.createdAt {
            parts.append("last " + last.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }
}

private struct ScheduleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var task: ScheduledTask
    let isNew: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $task.name, prompt: Text("Morning test run"))
                    Picker("Project", selection: $task.projectID) {
                        ForEach(model.projects) { Text($0.name).tag($0.id) }
                    }
                    Picker("Agent", selection: $task.agent) {
                        ForEach(model.agentChoices) { Text($0.displayName).tag($0) }
                    }
                    Picker("Access", selection: $task.access) {
                        ForEach(AccessLevel.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("In a worktree of its own", isOn: $task.inWorktree)
                }
                Section("When") {
                    Picker("Repeats", selection: $task.repeats) {
                        ForEach(ScheduledTask.Repeat.allCases) { Text($0.displayName).tag($0) }
                    }
                    if task.repeats == .hourly {
                        Stepper("Every \(task.everyHours) hour\(task.everyHours == 1 ? "" : "s")", value: $task.everyHours, in: 1...24)
                    } else {
                        if task.repeats == .weekly {
                            Picker("Day", selection: $task.weekday) {
                                ForEach(1...7, id: \.self) { Text(ScheduledTask.weekdayNames[$0 - 1]).tag($0) }
                            }
                        }
                        DatePicker("At", selection: time, displayedComponents: .hourAndMinute)
                    }
                }
                Section {
                    TextEditor(text: $task.prompt)
                        .font(.system(size: 12.5))
                        .frame(minHeight: 120)
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("Sent as the first message of each run's session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        model.deleteScheduledTask(task.id)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    task.name = task.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if isNew {
                        // The first run is the next matching time from now.
                        task.createdAt = .now
                        task.lastRun = nil
                    }
                    model.saveScheduledTask(task)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(task.name.trimmingCharacters(in: .whitespaces).isEmpty || task.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: 600)
    }

    /// Hour and minute through a time picker.
    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: task.hour, minute: task.minute, second: 0, of: .now) ?? .now },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                task.hour = parts.hour ?? 9
                task.minute = parts.minute ?? 0
            }
        )
    }
}
