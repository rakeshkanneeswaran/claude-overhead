import Foundation
import Security
import Testing
@testable import ChimloCore

/// Returns scripted results keyed by the argument list and records calls.
private final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [[String]: CommandResult] = [:]
    private var recorded: [(executable: String, arguments: [String])] = []

    func stub(_ arguments: [String], _ result: CommandResult) {
        lock.withLock { results[arguments] = result }
    }

    var calls: [(executable: String, arguments: [String])] {
        lock.withLock { recorded }
    }

    func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: String?,
        timeout: TimeInterval
    ) async -> CommandResult {
        lock.withLock {
            recorded.append((executable, arguments))
            return results[arguments] ?? CommandResult(status: 1, stderr: "unexpected command")
        }
    }
}

/// An in-memory token store standing in for the Keychain.
private final class FakeTokenStore: GitHubTokenStoring, @unchecked Sendable {
    struct Failure: Error {}

    private let lock = NSLock()
    private var token: String?
    private let failsReads: Bool

    init(token: String? = nil, failsReads: Bool = false) {
        self.token = token
        self.failsReads = failsReads
    }

    func read() throws -> String? {
        if failsReads { throw Failure() }
        return lock.withLock { token }
    }

    func save(_ token: String) throws {
        lock.withLock { self.token = token }
    }

    func delete() throws {
        lock.withLock { token = nil }
    }
}

/// A stand-in `gh` path that exists and is executable. The fake runner never
/// launches it.
private struct FakeExecutable {
    let directory: URL
    let path: String

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("overhead-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("gh").path
        FileManager.default.createFile(atPath: path, contents: Data(), attributes: [.posixPermissions: 0o755])
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum StatusFixtures {
    static let current = """
    github.com
      ✓ Logged in to github.com account octocat (keyring)
      - Active account: true
      - Git operations protocol: https
      - Token: gho_************************************
      - Token scopes: 'gist', 'read:org', 'repo', 'workflow'
    """

    static let multipleAccounts = """
    github.com
      ✓ Logged in to github.com account work-bot (keyring)
      - Active account: false
      - Git operations protocol: https
      - Token: gho_************************************

      ✓ Logged in to github.com account octocat (keyring)
      - Active account: true
      - Git operations protocol: ssh
      - Token: gho_************************************
    """

    static let legacy = """
    github.com
      ✓ Logged in to github.com as hubot (/Users/someone/.config/gh/hosts.yml)
      ✓ Git operations for github.com configured to use https protocol.
      ✓ Token: *******************
    """

    static let signedOut = "You are not logged into any GitHub hosts. To log in, run: gh auth login\n"
}

@Suite("GitHub credentials")
struct GitHubCredentialTests {
    private let statusArguments = ["auth", "status", "--hostname", "github.com"]
    private let tokenArguments = ["auth", "token", "--hostname", "github.com"]

    @Test("Every textual form of a credential redacts the token")
    func redaction() {
        let credential = GitHubCredential(token: "ghp_SUPERSECRET123", source: .githubCLI, account: "octocat")
        var dumped = ""
        dump(credential, to: &dumped)
        let forms = [
            credential.description,
            credential.debugDescription,
            "\(credential)",
            String(describing: credential),
            String(reflecting: credential),
            String(describing: [credential]),
            String(describing: Optional(credential)),
            dumped,
        ]
        for form in forms {
            #expect(!form.contains("SUPERSECRET"))
        }
        #expect(credential.description.contains("<redacted>"))
        #expect(credential.description.contains("octocat"))
        #expect(credential.token == "ghp_SUPERSECRET123")
    }

    @Test("Finds the first installed gh on the search path")
    func executableLookup() throws {
        let fake = try FakeExecutable()
        defer { fake.remove() }
        let cli = GitHubCLI(runner: FakeCommandRunner(), searchPaths: ["/nonexistent/gh", fake.path])
        #expect(cli.executable() == fake.path)
        #expect(GitHubCLI(runner: FakeCommandRunner(), searchPaths: ["/nonexistent/gh"]).executable() == nil)
    }

    @Test("Without gh installed, nothing is run")
    func notInstalled() async {
        let runner = FakeCommandRunner()
        let cli = GitHubCLI(runner: runner, searchPaths: ["/nonexistent/gh"])
        let status = await cli.status()
        let credential = await cli.credential()
        #expect(status == .notInstalled)
        #expect(credential == nil)
        #expect(runner.calls.isEmpty)
    }

    @Test("Status parses the signed-in account from current, multi-account, and legacy output")
    func signedInStatus() async throws {
        let fake = try FakeExecutable()
        defer { fake.remove() }

        let cases: [(CommandResult, String?)] = [
            (CommandResult(status: 0, stdout: StatusFixtures.current), "octocat"),
            (CommandResult(status: 0, stdout: StatusFixtures.multipleAccounts), "octocat"),
            (CommandResult(status: 0, stderr: StatusFixtures.legacy), "hubot"),
            (CommandResult(status: 0, stdout: "github.com\n  ✓ Signed in somehow\n"), nil),
        ]
        for (result, account) in cases {
            let runner = FakeCommandRunner()
            runner.stub(statusArguments, result)
            let status = await GitHubCLI(runner: runner, searchPaths: [fake.path]).status()
            #expect(status == .signedIn(account: account))
            #expect(runner.calls.first?.executable == fake.path)
        }
    }

    @Test("A failing status means signed out")
    func signedOutStatus() async throws {
        let fake = try FakeExecutable()
        defer { fake.remove() }
        let runner = FakeCommandRunner()
        runner.stub(statusArguments, CommandResult(status: 1, stderr: StatusFixtures.signedOut))
        let status = await GitHubCLI(runner: runner, searchPaths: [fake.path]).status()
        #expect(status == .signedOut)

        let timedOut = FakeCommandRunner()
        timedOut.stub(statusArguments, CommandResult(status: 0, stdout: StatusFixtures.current, timedOut: true))
        let timedOutStatus = await GitHubCLI(runner: timedOut, searchPaths: [fake.path]).status()
        #expect(timedOutStatus == .signedOut)
    }

    @Test("The CLI token is trimmed and tagged with its account")
    func cliCredential() async throws {
        let fake = try FakeExecutable()
        defer { fake.remove() }
        let runner = FakeCommandRunner()
        runner.stub(tokenArguments, CommandResult(status: 0, stdout: "gho_exampletoken123\n"))
        runner.stub(statusArguments, CommandResult(status: 0, stdout: StatusFixtures.current))

        let credential = try #require(await GitHubCLI(runner: runner, searchPaths: [fake.path]).credential())
        #expect(credential.token == "gho_exampletoken123")
        #expect(credential.source == .githubCLI)
        #expect(credential.account == "octocat")
    }

    @Test("A failed or malformed token read yields no credential")
    func cliCredentialFailure() async throws {
        let fake = try FakeExecutable()
        defer { fake.remove() }
        let outputs = [
            CommandResult(status: 1, stderr: "no oauth token found for github.com"),
            CommandResult(status: 0, stdout: "   \n"),
            CommandResult(status: 0, stdout: "two words\n"),
        ]
        for output in outputs {
            let runner = FakeCommandRunner()
            runner.stub(tokenArguments, output)
            let credential = await GitHubCLI(runner: runner, searchPaths: [fake.path]).credential()
            #expect(credential == nil)
        }
    }

    @Test("A stored personal access token wins over the CLI")
    func resolverPrefersStoredToken() async throws {
        let fake = try FakeExecutable()
        defer { fake.remove() }
        let runner = FakeCommandRunner()
        runner.stub(tokenArguments, CommandResult(status: 0, stdout: "gho_cli\n"))
        let resolver = GitHubCredentialResolver(
            tokenStore: FakeTokenStore(token: "  ghp_stored \n"),
            cli: GitHubCLI(runner: runner, searchPaths: [fake.path])
        )

        let credential = try #require(await resolver.resolve())
        #expect(credential.token == "ghp_stored")
        #expect(credential.source == .personalAccessToken)
        #expect(runner.calls.isEmpty)
    }

    @Test("An empty or unreadable store falls back to the CLI")
    func resolverFallsBack() async throws {
        let fake = try FakeExecutable()
        defer { fake.remove() }
        for store in [FakeTokenStore(), FakeTokenStore(token: "  "), FakeTokenStore(token: "x", failsReads: true)] {
            let runner = FakeCommandRunner()
            runner.stub(tokenArguments, CommandResult(status: 0, stdout: "gho_cli\n"))
            let resolver = GitHubCredentialResolver(tokenStore: store, cli: GitHubCLI(runner: runner, searchPaths: [fake.path]))
            let credential = try #require(await resolver.resolve())
            #expect(credential.token == "gho_cli")
            #expect(credential.source == .githubCLI)
        }
    }

    @Test("Saving, then deleting, a token through the store protocol")
    func storeProtocolRoundTrip() async throws {
        let store = FakeTokenStore()
        let resolver = GitHubCredentialResolver(
            tokenStore: store,
            cli: GitHubCLI(runner: FakeCommandRunner(), searchPaths: ["/nonexistent/gh"])
        )
        try store.save("ghp_saved")
        let saved = await resolver.resolve()
        #expect(saved?.token == "ghp_saved")
        try store.delete()
        let cleared = await resolver.resolve()
        #expect(cleared == nil)
    }

    @Test("The Keychain store refuses a blank token without touching the Keychain")
    func keychainRejectsBlankToken() {
        let store = KeychainTokenStore(service: "com.rakesh.overhead.tests.unused", account: "blank")
        #expect(throws: KeychainTokenStore.KeychainError(status: errSecParam)) {
            try store.save("  \n")
        }
        #expect(KeychainTokenStore.KeychainError(status: errSecItemNotFound).errorDescription?.contains("-25300") == true)
    }

    /// Writes one item to the login Keychain under a random service and removes
    /// it again. Opt-in (`OVERHEAD_KEYCHAIN_TESTS=1`) so a routine `make test`
    /// never touches the developer's Keychain; returns early when the Keychain
    /// is locked or unavailable, as on headless CI.
    @Test(
        "Keychain round trip",
        .enabled(if: ProcessInfo.processInfo.environment["OVERHEAD_KEYCHAIN_TESTS"] == "1")
    )
    func keychainRoundTrip() throws {
        let store = KeychainTokenStore(
            service: "com.rakesh.overhead.tests.\(UUID().uuidString)",
            account: "round-trip"
        )
        defer { try? store.delete() }
        do {
            try store.save("ghp_first_value")
        } catch {
            return
        }
        #expect(try store.read() == "ghp_first_value")
        try store.save("ghp_second_value")
        #expect(try store.read() == "ghp_second_value")
        try store.delete()
        #expect(try store.read() == nil)
        try store.delete()
    }
}
