import Darwin
import Foundation
import Security

/// Server and credential passwords in the login keychain, on this Mac only: never in Mountagent Desk's
/// JSON files, never synced to iCloud.
///
/// ssh gets them through askpass: `SSH_ASKPASS` points at the `mountagent-server` script
/// with `MOUNTAGENT_ASKPASS_ACCOUNT` set, and the helper answers only when it was started
/// by `/usr/bin/ssh` whose own parent is this app's executable (a terminal tab or a
/// connection test). Agents' commands don't use askpass: the app runs them and types the
/// password at ssh's own prompt (`ServerRun`). Anything else, an agent included, gets
/// nothing; reading the item with `security` makes macOS ask the user first.
public enum ServerPasswords {
    public static let askpassVariable = "MOUNTAGENT_ASKPASS_ACCOUNT"
    static let service = "dev.mountagent.server-password"

    public static func save(_ password: String, account: String) throws {
        delete(account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "Mountagent Desk server password",
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(password.utf8),
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)",
            ])
        }
    }

    public static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func password(account: String) -> String? {
        readPassword(account: account).password
    }

    /// Another secret kept the same way (a token for Copilot).
    public static func secret(account: String) -> String? {
        password(account: account)
    }

    /// The servers agents may read, kept here rather than in servers.json, which any agent
    /// running as the user could edit to give itself access. One item per data folder, so a
    /// debug run on a scratch store leaves the real list alone.
    static func agentAccessAccount(root: URL) -> String {
        let base = "agent-read-access"
        return root.standardizedFileURL == ProjectStore.standardRoot.standardizedFileURL ? base : base + ":" + root.standardizedFileURL.path
    }

    /// `nil` until it is first saved.
    public static func agentAccess(root: URL) -> Set<UUID>? {
        guard let text = readPassword(account: agentAccessAccount(root: root)).password,
              let ids = try? JSONDecoder().decode([UUID].self, from: Data(text.utf8))
        else { return nil }
        return Set(ids)
    }

    /// Who agents may `sudo -u` to, per server; kept here for the same reason.
    public static func agentSudoUsers(root: URL) -> [UUID: [String]] {
        guard let text = readPassword(account: agentAccessAccount(root: root) + ":sudo").password,
              let users = try? JSONDecoder().decode([UUID: [String]].self, from: Data(text.utf8))
        else { return [:] }
        return users
    }

    public static func saveAgentSudoUsers(_ users: [UUID: [String]], root: URL) throws {
        let data = try JSONEncoder().encode(users.filter { !$0.value.isEmpty })
        try save(String(decoding: data, as: UTF8.self), account: agentAccessAccount(root: root) + ":sudo")
    }

    public static func saveAgentAccess(_ ids: Set<UUID>, root: URL) throws {
        let data = try JSONEncoder().encode(ids.sorted { $0.uuidString < $1.uuidString })
        try save(String(decoding: data, as: UTF8.self), account: agentAccessAccount(root: root))
    }

    private static func readPassword(account: String) -> (password: String?, message: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return (nil, SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")
        }
        return (String(data: data, encoding: .utf8), "")
    }

    /// Answers ssh's password prompt; returns the exit status for askpass.
    /// A refusal says why on stderr, which ssh shows in the terminal.
    static func answerAskpass(account: String, prompt: String) -> Int32 {
        // A verification code or a key passphrase isn't saved: the person types it.
        guard prompt.localizedCaseInsensitiveContains("password"), !account.isEmpty else { return askInTerminal(prompt) }
        guard calledByAppSSH() else { return refuse("only ssh started by Mountagent Desk gets the saved password.") }
        let status = readPassword(account: account)
        guard let password = status.password else {
            return refuse("couldn't read the saved password from Keychain (\(status.message)). Save it again in the server's settings.")
        }
        FileHandle.standardOutput.write(Data((password + "\n").utf8))
        return 0
    }

    /// Asks on the terminal ssh runs in, without echo (a code from an authenticator app);
    /// agents and connection tests have none, so they get the reason instead.
    private static func askInTerminal(_ prompt: String) -> Int32 {
        var buffer = [CChar](repeating: 0, count: 1024)
        // A host-key question is answered with a visible yes or no.
        let flags = prompt.localizedCaseInsensitiveContains("(yes/no") ? RPP_REQUIRE_TTY | RPP_ECHO_ON : RPP_REQUIRE_TTY
        guard readpassphrase(prompt, &buffer, buffer.count, flags) != nil else {
            let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return refuse("the server asks \"\(question)\", which a person has to type in a terminal.")
        }
        FileHandle.standardOutput.write(Data((String(cString: buffer) + "\n").utf8))
        return 0
    }

    private static func refuse(_ reason: String) -> Int32 {
        FileHandle.standardError.write(Data("Mountagent Desk: \(reason)\n".utf8))
        return 1
    }

    /// True when this process's parent is /usr/bin/ssh and ssh's parent runs this same
    /// executable.
    static func calledByAppSSH() -> Bool {
        let ssh = getppid()
        guard executablePath(of: ssh) == "/usr/bin/ssh",
              let launcher = parent(of: ssh),
              let own = executablePath(of: getpid())
        else { return false }
        return executablePath(of: launcher) == own
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
