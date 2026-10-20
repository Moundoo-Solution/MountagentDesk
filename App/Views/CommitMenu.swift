import MountagentDeskKit
import SwiftUI

extension GitLog.Commit {
    /// "20 Oct 2026 11:08", as Git Graph shows it.
    var formattedDate: String {
        GitLog.Commit.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy HH:mm"
        return formatter
    }()
}

/// Right-click actions on a commit.
struct CommitMenu: View {
    let commit: GitLog.Commit

    var body: some View {
        Button("Copy SHA") { Clipboard.copy(commit.sha) }
        Button("Copy Short SHA") { Clipboard.copy(commit.shortSHA) }
        Button("Copy Message") { Clipboard.copy(commit.subject) }
        Divider()
        Button("Mention in Chat") {
            let mention = "commit \(commit.shortSHA) (\"\(commit.subject)\")"
            NotificationCenter.default.post(name: .insertIntoComposer, object: nil, userInfo: ["text": mention])
        }
    }

}

extension Notification.Name {
    /// Appends `userInfo["text"]` to the selected session's composer.
    static let insertIntoComposer = Notification.Name("MountagentDesk.insertIntoComposer")
}
