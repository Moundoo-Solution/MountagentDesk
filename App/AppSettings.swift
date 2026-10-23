import MountagentDeskKit
import AppKit
import Foundation
import UserNotifications

/// UserDefaults keys, shared by `@AppStorage` in views and by the model.
enum AppSettings {
    static let claudePathKey = "claudePath"
    /// The transcript and composer fill the pane instead of a centred reading column.
    static let fullWidthChatKey = "fullWidthChat"
    static let cursorPathKey = "cursorPath"
    static let defaultAgentKey = "defaultAgent"
    static let defaultAccessKey = "defaultAccess"
    static let notifyKey = "notifyWhenDone"
    static let chimeKey = "chimeWhenDone"
    static let badgeUnreadKey = "badgeUnreadSessions"

    /// A sound when a turn ends while the app is in front (on by default).
    static var chimes: Bool { UserDefaults.standard.object(forKey: chimeKey) as? Bool ?? true }
    /// The Dock badge also counts finished turns not yet looked at (on by default).
    static var badgesUnread: Bool { UserDefaults.standard.object(forKey: badgeUnreadKey) as? Bool ?? true }
    /// Off until the user asks: reading Cursor's token makes macOS show a keychain prompt.
    static let cursorUsageKey = "showCursorUsage"
    /// The `gh` account GitHub Copilot runs as; unset uses `copilot login`.
    static let copilotAccountKey = "copilotGitHubAccount"

    /// The agents switched on in Settings → Agents, as a comma list.
    static let enabledAgentsKey = "enabledAgents"

    // Read by more than one view.
    static let sidebarWidthKey = "sidebarWidth"
    static let defaultSidebarWidth = 260.0
    static let inspectorWidthKey = "inspectorWidth"
    static let defaultInspectorWidth = 420.0
    static let gitTabKey = "gitTab"
    static let dictationLanguageKey = "dictationLanguage"
    static let defaultDictationLanguage = "vi-VN"
    static let dictationSendsKey = "dictationSends"
    static let dictationMicrophoneKey = "dictationMicrophone"
    private static let legacyImportKey = "importedAgentDeskSettings"

    /// Copies the settings saved under the app's former bundle id (AgentDesk) once. Scratch
    /// runs with `MOUNTAGENT_DATA_DIR` leave the real settings alone.
    static func importLegacySettings() {
        let defaults = UserDefaults.standard
        guard ProcessInfo.processInfo.environment["MOUNTAGENT_DATA_DIR"] == nil,
              !defaults.bool(forKey: legacyImportKey) else { return }
        defaults.set(true, forKey: legacyImportKey)
        for (key, value) in defaults.persistentDomain(forName: "dev.agentdesk.AgentDesk") ?? [:]
        where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    /// Where a custom CLI path for `kind` is kept (Claude's and Cursor's keys predate the others).
    static func pathKey(for kind: AgentKind) -> String {
        switch kind {
        case .claude: claudePathKey
        case .cursor: cursorPathKey
        default: "\(kind.rawValue)Path"
        }
    }

    static var executableOverrides: [AgentKind: String] {
        let defaults = UserDefaults.standard
        var overrides: [AgentKind: String] = [:]
        for kind in AgentKind.allCases {
            overrides[kind] = defaults.string(forKey: pathKey(for: kind))
        }
        return overrides
    }

    static var enabledAgents: Set<AgentKind> {
        guard let stored = UserDefaults.standard.string(forKey: enabledAgentsKey) else {
            return Set(AgentKind.allCases.filter(\.enabledByDefault))
        }
        return Set(stored.split(separator: ",").compactMap { AgentKind(rawValue: String($0)) })
    }

    static func setEnabledAgents(_ agents: Set<AgentKind>) {
        UserDefaults.standard.set(AgentKind.allCases.filter(agents.contains).map(\.rawValue).joined(separator: ","), forKey: enabledAgentsKey)
    }

    /// The default agent, or the first one still switched on if it has been turned off.
    static var defaultAgent: AgentKind {
        let chosen = UserDefaults.standard.string(forKey: defaultAgentKey).flatMap(AgentKind.init(rawValue:)) ?? .claude
        let enabled = enabledAgents
        return enabled.contains(chosen) ? chosen : (AgentKind.allCases.first(where: enabled.contains) ?? .claude)
    }

    static var defaultAccess: AccessLevel {
        UserDefaults.standard.string(forKey: defaultAccessKey).flatMap(AccessLevel.init(rawValue:)) ?? .editFiles
    }
}

enum Notifier {
    /// The session a notification is about, in its user info.
    static let sessionKey = "sessionID"

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// A short system sound: Glass when a turn finished, Basso when it failed.
    @MainActor
    static func chime(failed: Bool) {
        NSSound(named: failed ? "Basso" : "Glass")?.play()
    }

    static func permissionNeeded(session: ChatSession, request: PermissionRequest) {
        let content = UNMutableNotificationContent()
        content.title = session.title
        content.body = "\(session.agent.displayName) wants to use \(request.toolName): \(request.summary)"
        content.sound = .default
        content.userInfo = [sessionKey: session.id.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
    }

    /// `failure` is the CLI's own error, if it reported one; no result at all means the turn
    /// ended without finishing (a crash, a sign-in problem, a stop).
    static func turnFinished(session: ChatSession, result: TurnResult?, failure: String? = nil) {
        guard UserDefaults.standard.object(forKey: AppSettings.notifyKey) as? Bool ?? true else { return }
        let content = UNMutableNotificationContent()
        content.title = session.title
        let agent = session.agent.displayName
        if let failure, result == nil || result?.isError == true {
            content.body = "\(agent) stopped: \(failure.prefix(140))"
        } else if result == nil {
            content.body = "\(agent) stopped without finishing."
        } else if result?.isError == true {
            content.body = "\(agent) stopped with an error."
        } else {
            content.body = "\(agent) finished."
        }
        content.sound = .default
        content.userInfo = [sessionKey: session.id.uuidString]
        let request = UNNotificationRequest(identifier: session.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
