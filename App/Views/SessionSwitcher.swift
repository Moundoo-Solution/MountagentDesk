import MountagentDeskKit
import SwiftUI

/// ⌘K: find a session by title, project or what was said in it, and open it.
struct SessionSwitcher: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SessionSearch.Result] = []
    @State private var selection = 0
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.textTertiary)
                TextField("Find a session by title, project or words in it", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit(open)
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.escape) {
                        dismiss()
                        return .handled
                    }
            }
            .padding(14)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                            row(result, selected: index == selection)
                                .id(index)
                                .onTapGesture {
                                    selection = index
                                    open()
                                }
                        }
                        if results.isEmpty {
                            Text(query.isEmpty ? "No sessions yet" : "Nothing matches \u{201C}\(query)\u{201D}")
                                .font(Theme.Font.ui)
                                .foregroundStyle(Theme.textTertiary)
                                .padding(14)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) { proxy.scrollTo(selection) }
            }
        }
        .frame(width: 620, height: 420)
        .background(Theme.background)
        .onAppear { focused = true }
        .task(id: query) {
            // Searched off the main thread: long sessions hold a lot of text.
            let sessions = Array(model.sessions.values)
            let names = Dictionary(uniqueKeysWithValues: model.projects.map { ($0.id, $0.name) })
            let query = query
            try? await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 120))
            guard !Task.isCancelled else { return }
            let found = await Task.detached { SessionSearch.results(for: query, in: sessions, projects: names) }.value
            guard !Task.isCancelled else { return }
            results = found
            selection = 0
        }
    }

    private func row(_ result: SessionSearch.Result, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(result.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if result.archived {
                    Text("Archived")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Text(result.project)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            if let snippet = result.snippet {
                Text(snippet)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .contentShape(Rectangle())
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !results.isEmpty else { return .handled }
        selection = min(max(selection + step, 0), results.count - 1)
        return .handled
    }

    private func open() {
        guard results.indices.contains(selection) else { return }
        let result = results[selection]
        if result.archived { model.setArchived(false, for: result.sessionID) }
        model.selectedSessionID = result.sessionID
        dismiss()
    }
}
