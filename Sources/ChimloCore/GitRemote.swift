import Foundation

/// A hosted repository identified from a git remote URL.
///
/// Only the host and repository path are kept. Credentials embedded in a
/// remote URL (`https://user:token@host/...`) and ports are dropped on purpose:
/// the identity is all Overhead needs, and a token must never reach a model
/// that may be logged, persisted, or shown.
public struct GitRemote: Equatable, Sendable, Codable, Hashable {
    public let host: String
    /// For GitHub this is the user or organization. Hosts with nested groups
    /// (GitLab subgroups) keep every leading component, joined with "/".
    public let owner: String
    public let name: String

    public init(host: String, owner: String, name: String) {
        self.host = host
        self.owner = owner
        self.name = name
    }

    public var isGitHub: Bool {
        let host = host.lowercased()
        return host == "github.com" || host == "www.github.com"
    }

    public var fullName: String { "\(owner)/\(name)" }

    public var webURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/\(owner)/\(name)"
        return components.url
    }

    /// Schemes git uses for network remotes. `file://` and bare paths are local
    /// clones with no hosted counterpart, so they are rejected.
    private static let networkSchemes: Set<String> = [
        "https", "http", "ssh", "git", "git+ssh", "ssh+git",
    ]

    /// Hosts that serve github.com repositories under another name
    /// (`ssh.github.com` is GitHub's SSH-over-443 endpoint).
    private static let gitHubAliases: Set<String> = ["www.github.com", "ssh.github.com"]

    /// Parses the URL forms git accepts for network remotes: scheme URLs
    /// (`https://`, `http://`, `ssh://`, `git://`, optionally with a user and
    /// port) and scp-like `[user@]host:owner/name`. A trailing `.git` and
    /// slashes are ignored. Returns `nil` for local paths, `file://`, and
    /// anything that does not name an owner and repository.
    public static func parse(_ url: String) -> GitRemote? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }

        if let separator = trimmed.range(of: "://") {
            let scheme = trimmed[..<separator.lowerBound].lowercased()
            guard networkSchemes.contains(scheme),
                  let components = URLComponents(string: trimmed),
                  let host = components.host
            else { return nil }
            return make(host: host, path: components.path)
        }

        // scp-like syntax. Git only treats it as remote when no slash precedes
        // the first colon; otherwise it is a local path such as `./a:b`.
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let authority = trimmed[..<colon]
        guard !authority.contains("/") else { return nil }
        let host = authority.split(separator: "@", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let path = String(trimmed[trimmed.index(after: colon)...])
        return make(host: host, path: path)
    }

    private static func make(host rawHost: String, path rawPath: String) -> GitRemote? {
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        // A single letter is a Windows drive (`C:/repo`), not a host.
        guard host.count > 1, isValidHost(host) else { return nil }
        if gitHubAliases.contains(host) { host = "github.com" }

        var path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.lowercased().hasSuffix(".git") {
            path.removeLast(4)
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.allSatisfy(isValidComponent) else { return nil }
        // github.com repositories are always exactly owner/name.
        if host == "github.com", parts.count != 2 { return nil }
        guard let name = parts.last else { return nil }
        let owner = parts.dropLast().joined(separator: "/")
        return GitRemote(host: host, owner: owner, name: name)
    }

    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
    private static let componentCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
    )

    private static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty,
              host.unicodeScalars.allSatisfy(hostCharacters.contains),
              !host.hasPrefix("."), !host.hasPrefix("-"), !host.hasSuffix("-"),
              !host.contains("..")
        else { return false }
        return true
    }

    private static func isValidComponent(_ component: String) -> Bool {
        guard !component.isEmpty, component != ".", component != ".." else { return false }
        return component.unicodeScalars.allSatisfy(componentCharacters.contains)
    }
}
