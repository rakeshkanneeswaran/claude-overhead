import ChimloCore
import Foundation

/// The real network transport for `GitHubClient`. It lives in the app, not
/// in Core, so Core stays free of networking.
enum GitHubNetwork {
    /// A dedicated session with no URL cache or cookies: ETags are handled
    /// here, and a shared cache could answer a conditional request on our
    /// behalf, hiding the 304 the ETag cache relies on.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        return URLSession(configuration: configuration)
    }()

    static let transport: GitHubTransport = { request in
        let (data, response) = try await GitHubNetwork.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

}
