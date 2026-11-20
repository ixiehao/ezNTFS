import EzNTFSCore
import Foundation

enum MountRetry {
    static func run(partition: String, mount: () throws -> Void,
                    wait: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws {
        let openBusy = "Error opening '/dev/\(partition)': Resource busy"

        for delay in [1, 2, 4] {
            do {
                try mount()
                return
            } catch let error as EZError where error.message.split(separator: "\n").first == Optional(Substring(openBusy))
                                            && !error.message.contains("未能恢复只读挂载") {
                // macOS can open the device before its read-only mount is visible.
                try await wait(.seconds(delay))
            }
        }
        try mount()
    }
}
