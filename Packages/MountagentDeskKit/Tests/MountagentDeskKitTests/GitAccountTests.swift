import Foundation
import Testing
@testable import MountagentDeskKit

@Suite struct GitAccountTests {
    private func repo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskAcct-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path, "init", "-q"]
        try process.run()
        process.waitUntilExit()
        return root
    }

    @Test func appliesAndClearsAnAccount() throws {
        let root = try repo()
        let repository = GitRepository(root: root)
        let account = GitAccount(label: "Personal", name: "Son Tran", email: "son@example.com", sshKeyPath: "/Users/me/.ssh/id personal")
        try repository.apply(account)

        let identity = repository.identity()
        #expect(identity.name == "Son Tran")
        #expect(identity.email == "son@example.com")
        #expect(identity.isLocal)
        #expect(identity.sshCommand == "ssh -i '/Users/me/.ssh/id personal' -o IdentitiesOnly=yes")

        repository.clearAccount()
        let cleared = repository.identity()
        #expect(!cleared.isLocal)
        #expect(cleared.sshCommand == nil)
    }

    @Test func switchesHTTPSRemotesToSSH() throws {
        #expect(GitRepository.sshURL(fromHTTPS: "https://github.com/acme/storefront") == "git@github.com:acme/storefront.git")
        #expect(GitRepository.sshURL(fromHTTPS: "https://github.com/a/b.git") == "git@github.com:a/b.git")
        #expect(GitRepository.sshURL(fromHTTPS: "git@github.com:a/b.git") == nil)
        #expect(GitRepository.sshURL(fromHTTPS: "https://github.com/only-owner") == nil)

        let root = try repo()
        let repository = GitRepository(root: root)
        try GitInspector(root: root).git(["remote", "add", "origin", "https://github.com/a/b"])
        #expect(repository.identity().remoteIsHTTPS)
        #expect(try repository.switchRemoteToSSH() == "git@github.com:a/b.git")
        #expect(repository.identity().remoteURL == "git@github.com:a/b.git")
    }

    @Test func findsTheWebPageOfARemote() {
        #expect(GitRepository.webURL(fromRemote: "git@github.com:acme/website.git")?.absoluteString == "https://github.com/acme/website")
        #expect(GitRepository.webURL(fromRemote: "https://github.com/acme/website.git")?.absoluteString == "https://github.com/acme/website")
        #expect(GitRepository.webURL(fromRemote: "ssh://git@github.com/a/b")?.absoluteString == "https://github.com/a/b")
        #expect(GitRepository.webURL(fromRemote: "/tmp/remote.git") == nil)
    }

    @Test func recognisesHTTPSSignInFailures() {
        #expect(GitRepository.isHTTPSSignInFailure("remote: Repository not found.\nfatal: repository 'https://github.com/acme/website.git/' not found"))
        #expect(GitRepository.isHTTPSSignInFailure("fatal: could not read Username for 'https://github.com': terminal prompts disabled"))
        #expect(!GitRepository.isHTTPSSignInFailure("ERROR: Repository not found.\nfatal: Could not read from remote repository."))
        #expect(!GitRepository.isHTTPSSignInFailure("error: failed to push some refs to 'https://github.com/a/b.git'"))
    }

    @Test func listsAndGeneratesKeys() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MountagentDeskSSH-\(UUID().uuidString)")
        let key = try SSHKeys.generate(named: "work github", comment: "me@work.com", in: directory)
        #expect(key.name == "work-github")
        #expect(key.comment == "me@work.com")
        #expect(key.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(SSHKeys.list(in: directory).map(\.name) == ["work-github"])
        #expect(throws: (any Error).self) { try SSHKeys.generate(named: "work github", comment: "x", in: directory) }
    }

    @Test func readsGitHubAnswers() {
        #expect(SSHKeys.parseTest("Hi octocat-work! You've successfully authenticated, but GitHub does not provide shell access.") == .authenticated(username: "octocat-work"))
        #expect(SSHKeys.parseTest("git@github.com: Permission denied (publickey).\n") == .failed("git@github.com: Permission denied (publickey)."))
    }

    @Test func findsTheGitHubKeyInSSHConfig() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-config-\(UUID().uuidString)")
        try """
        Host gitlab.com
            IdentityFile ~/.ssh/gitlab
        Host github.com
            HostName github.com
            User octocat-work
            IdentityFile /Users/me/.ssh/octocat-work-GitHub
        """.write(to: config, atomically: true, encoding: .utf8)
        #expect(GitAccountImport.githubKey(in: config) == "/Users/me/.ssh/octocat-work-GitHub")
    }
}

@Suite struct GitHubCLITests {
    @Test func readsSignedInAccounts() {
        let status = """
        github.com
          ✓ Logged in to github.com account octocat-work (keyring)
          - Active account: true
          - Git operations protocol: ssh
          - Token: gho_************************************

          ✓ Logged in to github.com account octocat (keyring)
          - Active account: false
        """
        #expect(GitHubCLI.parseAccounts(status) == ["octocat-work", "octocat"])
        #expect(GitHubCLI.parseAccounts("✓ Logged in to github.com as olduser (oauth_token)") == ["olduser"])
        #expect(GitHubCLI.parseAccounts("You are not logged into any GitHub hosts.") == [])
    }

    @Test func picksThePrimaryVerifiedEmail() {
        let emails = #"""
        [{"email":"old@x.com","primary":false,"verified":true},
         {"email":"main@x.com","primary":true,"verified":true},
         {"email":"unverified@x.com","primary":false,"verified":false}]
        """#
        #expect(GitHubCLI.primaryEmail(from: emails) == "main@x.com")
        #expect(GitHubCLI.primaryEmail(from: #"[{"email":"a@x.com","primary":true,"verified":false}]"#) == nil)
    }

    @Test func signsInThroughTheBrowser() {
        let command = GitHubCLI.loginCommand(gh: "/opt/homebrew/bin/gh")
        #expect(command.contains("--web"))
        #expect(command.contains("admin:public_key"))
        #expect(command.contains("--skip-ssh-key"))
    }
}
