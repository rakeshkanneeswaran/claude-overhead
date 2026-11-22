import Foundation

/// A GitHub API token and where it came from.
///
/// Every textual form of this value redacts the token, including `dump()` and
/// string interpolation, so passing a credential to a logger or a debug print
/// can never leak it. Read `token` only to build an Authorization header.
public struct GitHubCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Source: String, Sendable {
        /// Borrowed from `gh auth token`; the GitHub CLI owns its lifecycle.
        case githubCLI
        /// Pasted by the user and stored in Overhead's Keychain item.
        case personalAccessToken
    }

    public let token: String
    public let source: Source
    public let account: String?

    public init(token: String, source: Source, account: String? = nil) {
        self.token = token
        self.source = source
        self.account = account
    }

    public var description: String {
        "GitHubCredential(source: \(source.rawValue), account: \(account ?? "unknown"), token: <redacted>)"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: [
            "source": source.rawValue,
            "account": account ?? "unknown",
            "token": "<redacted>",
        ])
    }
}

/// Persistent storage for a user-supplied personal access token. A protocol so
/// credential resolution can be tested without touching the real Keychain.
public protocol GitHubTokenStoring: Sendable {
    func read() throws -> String?
    func save(_ token: String) throws
    func delete() throws
}

public enum GitHubCLIStatus: Equatable, Sendable {
    case notInstalled
    case signedOut
    case signedIn(account: String?)
}

/// Reuses the GitHub CLI's existing sign-in so most users never paste a token.
public struct GitHubCLI: Sendable {
    /// Homebrew on Apple silicon, Homebrew on Intel, then a system install.
    /// Fixed paths matter because an app opened from Finder gets a minimal PATH.
    public static let defaultSearchPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    public static let host = "github.com"

    public let runner: any CommandRunning
    public let searchPaths: [String]
    public let timeout: TimeInterval

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        searchPaths: [String] = GitHubCLI.defaultSearchPaths,
        timeout: TimeInterval = 10
    ) {
        self.runner = runner
        self.searchPaths = searchPaths
        self.timeout = timeout
    }

    public func executable() -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Exit status 0 means signed in. The output only names the account; older
    /// gh versions print it to stderr, so both streams are searched.
    public func status() async -> GitHubCLIStatus {
        guard let executable = executable() else { return .notInstalled }
        let result = await runner.run(
            executable,
            ["auth", "status", "--hostname", Self.host],
            workingDirectory: nil,
            timeout: timeout
        )
        if result.status == ProcessCommandRunner.executableNotFoundStatus { return .notInstalled }
        guard result.succeeded else { return .signedOut }
        return .signedIn(account: Self.account(fromStatusOutput: result.stdout + "\n" + result.stderr))
    }

    /// The CLI's token for github.com, or `nil` when signed out or gh fails.
    public func credential() async -> GitHubCredential? {
        guard let executable = executable() else { return nil }
        async let tokenResult = runner.run(
            executable,
            ["auth", "token", "--hostname", Self.host],
            workingDirectory: nil,
            timeout: timeout
        )
        async let statusResult = status()
        let result = await tokenResult
        guard result.succeeded else { return nil }
        let token = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        // A token never contains whitespace; anything else is not a token.
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else { return nil }
        var account: String?
        if case .signedIn(let login) = await statusResult { account = login }
        return GitHubCredential(token: token, source: .githubCLI, account: account)
    }

    /// Finds the signed-in login in `gh auth status` output. Current gh prints
    /// "Logged in to github.com account <login> (keyring)" per account with an
    /// "Active account: true" line under the active one; older gh printed
    /// "Logged in to github.com as <login> (<config path>)".
    static func account(fromStatusOutput output: String) -> String? {
        var accounts: [(login: String, active: Bool)] = []
        let marker = "Logged in to \(host) "
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let range = line.range(of: marker) {
                let words = line[range.upperBound...].split(separator: " ")
                guard words.count >= 2, words[0] == "account" || words[0] == "as" else { continue }
                accounts.append((String(words[1]), false))
            } else if line.lowercased().contains("active account: true"), let last = accounts.indices.last {
                accounts[last].active = true
            }
        }
        return (accounts.first(where: \.active) ?? accounts.first)?.login
    }
}

/// Picks the credential Overhead uses for GitHub.
///
/// A stored personal access token wins because the user deliberately entered
/// it in Overhead, often to use a narrower or different account than their gh
/// sign-in. Otherwise the GitHub CLI's token is borrowed.
public struct GitHubCredentialResolver: Sendable {
    public let tokenStore: any GitHubTokenStoring
    public let cli: GitHubCLI

    public init(tokenStore: any GitHubTokenStoring = KeychainTokenStore(), cli: GitHubCLI = GitHubCLI()) {
        self.tokenStore = tokenStore
        self.cli = cli
    }

    /// A Keychain read failure falls through to the CLI rather than failing:
    /// a locked or unavailable Keychain should not hide a working gh sign-in.
    public func resolve() async -> GitHubCredential? {
        if let stored = try? tokenStore.read() {
            let token = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                return GitHubCredential(token: token, source: .personalAccessToken)
            }
        }
        return await cli.credential()
    }
}
