import Foundation

public enum ReleaseCheck: Equatable, Sendable {
    case updateAvailable(version: String, page: URL)
    case upToDate
    case noPublicRelease
    case rateLimited
    case offline
    case unavailable

    public static let projectPage = URL(string: "https://github.com/ixiehao/ezNTFS")!
    private static let endpoint = URL(string: "https://api.github.com/repos/ixiehao/ezNTFS/releases/latest")!

    public static func latest(installedVersion: String) async -> Self {
        await latest(installedVersion: installedVersion, load: fetch)
    }

    static func latest(
        installedVersion: String,
        load: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async -> Self {
        guard let current = versionComponents(installedVersion) else { return .unavailable }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ezNTFS", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await load(request)
            guard let response = response as? HTTPURLResponse, response.url == endpoint else { return .unavailable }
            if response.statusCode == 404 { return .noPublicRelease }
            if response.statusCode == 429 || (response.statusCode == 403 && isRateLimited(response, body: data)) {
                return .rateLimited
            }
            guard response.statusCode == 200,
                  let release = try? JSONDecoder().decode(Release.self, from: data),
                  !release.draft, !release.prerelease,
                  let candidate = versionComponents(release.tag_name) else { return .unavailable }
            guard current.lexicographicallyPrecedes(candidate) else { return .upToDate }
            let page = projectPage.appending(path: "releases/tag").appending(path: release.tag_name)
            return .updateAvailable(version: candidate.map(String.init).joined(separator: "."), page: page)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            return .offline
        } catch {
            return .unavailable
        }
    }

    private static func isRateLimited(_ response: HTTPURLResponse, body: Data) -> Bool {
        if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" ||
            response.value(forHTTPHeaderField: "Retry-After") != nil {
            return true
        }
        let error = try? JSONDecoder().decode(APIError.self, from: body)
        return error?.message.localizedCaseInsensitiveContains("rate limit") == true
    }

    private static func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    private static func versionComponents(_ tag: String) -> [UInt]? {
        let value = tag.hasPrefix("v") ? tag.dropFirst() : tag[...]
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let components = parts.compactMap { part -> UInt? in
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return UInt(part)
        }
        return components.count == 3 ? components : nil
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }

    private struct APIError: Decodable {
        let message: String
    }
}
