import Foundation
import Testing
@testable import EzNTFSCore

struct ReleaseCheckTests {
    private let endpoint = URL(string: "https://api.github.com/repos/ixiehao/ezNTFS/releases/latest")!

    @Test
    func reportsNewerStableReleasesAndBuildsTheTrustedPage() async {
        let result = await check(tag: "v0.4.10")
        #expect(result == .updateAvailable(version: "0.4.10", page:
            URL(string: "https://github.com/ixiehao/ezNTFS/releases/tag/v0.4.10")!))
    }

    @Test(arguments: ["v0.4.8", "0.4.7", "v0.3.99"])
    func reportsEqualAndOlderReleasesAsCurrent(tag: String) async {
        #expect(await check(tag: tag) == .upToDate)
    }

    @Test(arguments: ["v0.5.0-beta.1", "v0.5", "v0..5", "v0.5.0/extra", "v0.5.99999999999999999999999"])
    func rejectsUnsupportedTags(tag: String) async {
        #expect(await check(tag: tag) == .unavailable)
    }

    @Test
    func rejectsDraftsPrereleasesAndUnexpectedResponseOrigins() async {
        #expect(await check(draft: true) == .unavailable)
        #expect(await check(prerelease: true) == .unavailable)
        #expect(await check(responseURL: URL(string: "https://example.com")!) == .unavailable)
    }

    @Test
    func distinguishesMissingReleaseFromServiceAndNetworkErrors() async {
        #expect(await check(status: 404) == .noPublicRelease)
        #expect(await check(status: 403) == .unavailable)
        #expect(await check(status: 500) == .unavailable)
        #expect(await ReleaseCheck.latest(installedVersion: "0.4.8", load: { _ in
            throw URLError(.notConnectedToInternet)
        }) == .offline)
    }

    @Test
    func detectsGitHubRateLimiting() async {
        #expect(await check(status: 429) == .rateLimited)
        #expect(await check(status: 403, headers: ["X-RateLimit-Remaining": "0"]) == .rateLimited)
        #expect(await check(status: 403, headers: ["Retry-After": "60"]) == .rateLimited)
        #expect(await check(status: 403, message: "You have exceeded a secondary rate limit.") == .rateLimited)
    }

    private func check(tag: String = "v0.5.0", draft: Bool = false, prerelease: Bool = false,
                       status: Int = 200, responseURL: URL? = nil, headers: [String: String] = [:],
                       message: String = "") async -> ReleaseCheck {
        await ReleaseCheck.latest(installedVersion: "0.4.8") { request in
            #expect(request.url == endpoint)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let data = try JSONSerialization.data(withJSONObject: [
                "tag_name": tag, "draft": draft, "prerelease": prerelease,
                "html_url": "https://example.com/untrusted", "message": message,
            ])
            let response = HTTPURLResponse(url: responseURL ?? endpoint, statusCode: status,
                                           httpVersion: nil, headerFields: headers)!
            return (data, response)
        }
    }
}
