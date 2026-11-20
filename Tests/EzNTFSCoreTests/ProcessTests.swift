import EzNTFSCore
import Foundation
import Testing

struct ProcessTests {
    @Test func queryReturnsOutput() throws {
        let result = try Tool.run("/usr/bin/printf", ["test"], queryTimeout: .seconds(2))
        #expect(String(decoding: result, as: UTF8.self) == "test")
    }

    @Test func versionProbeCanReadStandardErrorWithoutChangingDefaultOutput() throws {
        let arguments = ["-c", "printf status >&2"]
        #expect(try Tool.run("/bin/zsh", arguments).isEmpty)
        let result = try Tool.run("/bin/zsh", arguments, queryTimeout: .seconds(2), includeStandardError: true)
        #expect(String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "status")
    }

    @Test func queryTimeoutReapsAnUnresponsiveProcess() {
        let clock = ContinuousClock()
        let start = clock.now
        #expect(throws: EZError.self) {
            try Tool.run("/bin/zsh", ["-c", "trap '' TERM; exec /bin/sleep 5"], queryTimeout: .milliseconds(100))
        }
        #expect(start.duration(to: clock.now) < .seconds(3))
    }
}
