import EzNTFSCore
import Foundation
import Testing

struct ProcessTests {
    @Test func queryReturnsOutput() throws {
        let result = try Tool.run("/usr/bin/printf", ["test"], queryTimeout: 2)
        #expect(String(decoding: result, as: UTF8.self) == "test")
    }

    @Test func versionProbeCanReadStandardErrorWithoutChangingDefaultOutput() throws {
        let arguments = ["-c", "printf status >&2"]
        #expect(try Tool.run("/bin/zsh", arguments).isEmpty)
        let result = try Tool.run("/bin/zsh", arguments, queryTimeout: 2, includeStandardError: true)
        #expect(String(decoding: result, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "status")
    }

    @Test func queryTimeoutReapsAnUnresponsiveProcess() {
        let deadline = DispatchTime.now() + .seconds(3)
        #expect(throws: EZError.self) {
            try Tool.run("/bin/zsh", ["-c", "trap '' TERM; exec /bin/sleep 5"], queryTimeout: 0.1)
        }
        #expect(DispatchTime.now() < deadline)
    }
}
