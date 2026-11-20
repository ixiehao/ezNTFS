import Darwin
import Foundation

public struct EZError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum Tool {
    // Regular files drain both streams without risking a pipe deadlock.
    public static func run(_ executable: String, _ arguments: [String], queryTimeout: Duration? = nil,
                           environment: [String: String] = [:], includeStandardError: Bool = false) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ezntfs-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("out")
        let errors = directory.appendingPathComponent("err")
        try Data().write(to: output)
        try Data().write(to: errors)
        let outHandle = try FileHandle(forWritingTo: output)
        let errHandle = try FileHandle(forWritingTo: errors)
        defer { try? outHandle.close(); try? errHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
        ].merging(environment) { _, override in override }
        let completion = DispatchSemaphore(value: 0)
        if queryTimeout != nil { process.terminationHandler = { _ in completion.signal() } }
        try process.run()
        if let queryTimeout, completion.wait(timeout: .now() + queryTimeout.timeInterval) == .timedOut {
            if process.isRunning { process.terminate() }
            if completion.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 0.25)
            }
            throw EZError("系统磁盘查询超时，请稍后重试。")
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = try Data(contentsOf: errors)
            let fallback = try Data(contentsOf: output)
            let detail = String(decoding: (data.isEmpty ? fallback : data).prefix(1800), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw EZError(detail.isEmpty ? "\(URL(fileURLWithPath: executable).lastPathComponent) 退出码 \(process.terminationStatus)" : detail)
        }
        let result = try Data(contentsOf: output)
        guard includeStandardError else { return result }
        return try result + Data([10]) + Data(contentsOf: errors)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

public func canonicalPath(_ path: String) throws -> String {
    guard let resolved = realpath(path, nil) else { throw posixError("解析实际路径") }
    defer { free(resolved) }
    return String(cString: resolved)
}

public struct VolumeMount: Sendable, Equatable {
    public let path: String
    public let kind: String
    public let readOnly: Bool
    public let availableCapacity: Int64?

    public init(path: String, kind: String, readOnly: Bool, availableCapacity: Int64? = nil) {
        self.path = path
        self.kind = kind
        self.readOnly = readOnly
        self.availableCapacity = availableCapacity
    }

    // MNT_NOWAIT returns the kernel's cached mount statistics without asking each file system.
    static func snapshot() throws -> [String: VolumeMount] {
        let initialCount = getfsstat(nil, 0, MNT_NOWAIT)
        guard initialCount >= 0 else { throw posixError("读取系统挂载表") }
        var capacity = Int(initialCount) + 16
        while true {
            var entries = Array(repeating: statfs(), count: capacity)
            let count = entries.withUnsafeMutableBufferPointer { buffer in
                getfsstat(buffer.baseAddress, Int32(clamping: buffer.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
            }
            guard count >= 0 else { throw posixError("读取系统挂载表") }
            if count >= capacity {
                capacity *= 2
                continue
            }
            var mounts: [String: VolumeMount] = [:]
            for entry in entries.prefix(Int(count)) {
                let source = fileSystemString(entry.f_mntfromname)
                guard let device = source.wholeMatch(of: #/\/dev\/r?(disk[0-9]+(?:s[0-9]+)?)/#)?.1 else { continue }
                let (bytes, overflow) = UInt64(entry.f_bavail).multipliedReportingOverflow(by: UInt64(entry.f_bsize))
                mounts[String(device)] = VolumeMount(
                    path: fileSystemString(entry.f_mntonname), kind: fileSystemString(entry.f_fstypename),
                    readOnly: entry.f_flags & UInt32(MNT_RDONLY) != 0,
                    availableCapacity: overflow ? nil : Int64(exactly: bytes)
                )
            }
            return mounts
        }
    }
}

private func fileSystemString<T>(_ value: T) -> String {
    withUnsafeBytes(of: value) {
        String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

public struct MountedDisk: Sendable, Equatable {
    public let source: String
    public let path: String
    public let kind: String
    public let readOnly: Bool
    public let device: dev_t

    public init(source: String, path: String, kind: String, readOnly: Bool, device: dev_t) {
        self.source = source
        self.path = path
        self.kind = kind
        self.readOnly = readOnly
        self.device = device
    }

    public static func at(_ path: String) throws -> MountedDisk {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { throw posixError("读取挂载状态") }
        var attributes = stat()
        guard lstat(path, &attributes) == 0 else { throw posixError("读取目录状态") }
        return MountedDisk(source: fileSystemString(fs.f_mntfromname), path: fileSystemString(fs.f_mntonname),
                           kind: fileSystemString(fs.f_fstypename), readOnly: (fs.f_flags & UInt32(MNT_RDONLY)) != 0,
                           device: attributes.st_dev)
    }

    public func attached(to partition: String) -> Bool {
        source == "/dev/\(partition)" || source == "/dev/r\(partition)"
    }
}

func posixError(_ operation: String) -> EZError {
    let code = errno
    return EZError("\(operation)失败（\(code)）：\(String(cString: strerror(code)))")
}
