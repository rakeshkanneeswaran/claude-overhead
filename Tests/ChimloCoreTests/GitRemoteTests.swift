import Foundation
import Testing
@testable import ChimloCore

@Suite("Git remote parsing")
struct GitRemoteTests {
    @Test("Accepts every network URL form git supports", arguments: [
        ("https://github.com/octo/app", "github.com", "octo", "app"),
        ("https://github.com/octo/app.git", "github.com", "octo", "app"),
        ("https://github.com/octo/app/", "github.com", "octo", "app"),
        ("https://github.com/octo/app.git/", "github.com", "octo", "app"),
        ("http://github.com/octo/app.git", "github.com", "octo", "app"),
        ("https://GitHub.com/Octo/My.App.git", "github.com", "Octo", "My.App"),
        ("https://www.github.com/octo/app", "github.com", "octo", "app"),
        ("https://user:secret-token@github.com/octo/app.git", "github.com", "octo", "app"),
        ("git@github.com:octo/app.git", "github.com", "octo", "app"),
        ("git@github.com:octo/app", "github.com", "octo", "app"),
        ("git@github.com:/octo/app.git", "github.com", "octo", "app"),
        ("github.com:octo/app.git", "github.com", "octo", "app"),
        ("ssh://git@github.com/octo/app.git", "github.com", "octo", "app"),
        ("ssh://git@github.com:22/octo/app.git", "github.com", "octo", "app"),
        ("ssh://git@ssh.github.com:443/octo/app.git", "github.com", "octo", "app"),
        ("git+ssh://git@github.com/octo/app.git", "github.com", "octo", "app"),
        ("git://github.com/octo/app.git", "github.com", "octo", "app"),
        ("  https://github.com/octo/app.git\n", "github.com", "octo", "app"),
        ("https://github.example.com/team/service.git", "github.example.com", "team", "service"),
        ("git@ghe.corp.internal:platform/api.git", "ghe.corp.internal", "platform", "api"),
        ("https://gitlab.com/group/subgroup/project.git", "gitlab.com", "group/subgroup", "project"),
        ("git@github-work:octo/app.git", "github-work", "octo", "app"),
    ])
    func parsesRemote(input: String, host: String, owner: String, name: String) throws {
        let remote = try #require(GitRemote.parse(input))
        #expect(remote.host == host)
        #expect(remote.owner == owner)
        #expect(remote.name == name)
    }

    @Test("Rejects local paths, file URLs, and garbage", arguments: [
        "",
        "   ",
        "not a url",
        "/Users/someone/repos/app",
        "/Users/someone/repos/app.git",
        "./app",
        "../app",
        "~/repos/app",
        "./dir:with/colon",
        "file:///Users/someone/repos/app.git",
        "C:/repos/app",
        "https://github.com/",
        "https://github.com/octo",
        "https://github.com/octo/app/pull/12",
        "git@github.com:octo",
        "git@github.com:",
        "ftp://github.com/octo/app.git",
        "https://github.com/octo/../app",
        "https://exa mple.com/octo/app",
        "https://-bad-.com/octo/app",
    ])
    func rejectsNonRemote(input: String) {
        #expect(GitRemote.parse(input) == nil)
    }

    @Test("GitHub identity, full name, and web URL")
    func derivedProperties() throws {
        let remote = try #require(GitRemote.parse("git@github.com:octo/app.git"))
        #expect(remote.isGitHub)
        #expect(remote.fullName == "octo/app")
        #expect(remote.webURL?.absoluteString == "https://github.com/octo/app")

        let enterprise = try #require(GitRemote.parse("https://ghe.corp.internal/platform/api"))
        #expect(!enterprise.isGitHub)
        #expect(enterprise.webURL?.absoluteString == "https://ghe.corp.internal/platform/api")

        #expect(GitRemote(host: "www.github.com", owner: "o", name: "r").isGitHub)
    }

    @Test("Credentials embedded in a remote URL are never kept")
    func dropsCredentials() throws {
        let remote = try #require(GitRemote.parse("https://someone:ghp_supersecret@github.com/octo/app.git"))
        let encoded = try JSONEncoder().encode(remote)
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("supersecret"))
        #expect(!String(describing: remote).contains("supersecret"))
    }

    @Test("Repository info prefers origin, then upstream, then a name-ordered GitHub remote")
    func gitHubRemotePreference() throws {
        let origin = try #require(GitRemote.parse("git@github.com:me/app.git"))
        let upstream = try #require(GitRemote.parse("https://github.com/org/app.git"))
        let gitlab = try #require(GitRemote.parse("https://gitlab.com/me/app.git"))
        let alpha = try #require(GitRemote.parse("https://github.com/alpha/app.git"))
        let beta = try #require(GitRemote.parse("https://github.com/beta/app.git"))

        func info(_ remotes: [String: GitRemote]) -> GitRepositoryInfo {
            GitRepositoryInfo(root: "/r", branch: "b", headCommit: nil, defaultBranch: nil, remotes: remotes)
        }

        #expect(info(["origin": origin, "upstream": upstream]).gitHubRemote == origin)
        #expect(info(["origin": gitlab, "upstream": upstream]).gitHubRemote == upstream)
        #expect(info(["origin": gitlab, "zeta": beta, "alpha": alpha]).gitHubRemote == alpha)
        #expect(info(["origin": gitlab]).gitHubRemote == nil)
        #expect(info([:]).gitHubRemote == nil)
    }
}
