import Darwin
import Foundation

private final class ExternalIPRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme == "https",
              url.host == "api64.ipify.org",
              url.port == nil || url.port == 443 else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum ExternalIPService {
    static func fetch() async throws -> String {
        guard let url = URL(string: "https://api64.ipify.org?format=json") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        let redirectDelegate = ExternalIPRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.url?.scheme == "https",
              http.url?.host == "api64.ipify.org",
              http.url?.port == nil || http.url?.port == 443 else {
            throw URLError(.badServerResponse)
        }
        let value = try JSONDecoder().decode(PublicIPResponse.self, from: data).ip
        guard isIPAddress(value) else { throw URLError(.cannotParseResponse) }
        return value
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
        var ipv6 = in6_addr()
        return value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1
    }
}
