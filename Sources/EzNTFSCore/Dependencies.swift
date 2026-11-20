import Foundation

public enum DependencyStatus: Equatable, Sendable {
    case missing
    case unavailable(String)
    case ready(path: String, version: String)

    public var path: String? {
        if case .ready(let path, _) = self { return path }
        return nil
    }

    public var summary: String {
        switch self {
        case .missing: "未安装"
        case .unavailable(let cause): cause
        case .ready(_, let version): version
        }
    }
}

public struct DependencyReport: Equatable, Sendable {
    public let macFUSE: DependencyStatus
    public let ntfs3g: DependencyStatus
    public let service: DependencyStatus
    public let driverUsage: DriverUsage

    public init(macFUSE: DependencyStatus, ntfs3g: DependencyStatus, service: DependencyStatus, driverUsage: DriverUsage = .idle) {
        self.macFUSE = macFUSE
        self.ntfs3g = ntfs3g
        self.service = service
        self.driverUsage = driverUsage
    }

    public var canMountReadWrite: Bool { macFUSE.path != nil && ntfs3g.path != nil && service.path != nil }
}

public enum Dependencies {
    public static let macFUSEWebsite = URL(string: "https://macfuse.github.io/")!

    public static func checkDriverUsage() -> DriverUsage {
        DriverUsage.inspect(under: SystemDriver.driverReceipt.deletingLastPathComponent().path)
    }

    public static func inspect() -> DependencyReport {
        let fuse = status(at: SystemDriver.fuseBundle) {
            (SystemDriver.fuseBundle.path, try SystemDriver.inspectFUSE())
        }
        let driver = status(at: SystemDriver.driverReceipt) {
            let installed = try SystemDriver.inspectDriver()
            let output = try Tool.run(installed.path, ["--version"], queryTimeout: .seconds(5), includeStandardError: true)
            guard String(decoding: output, as: UTF8.self).contains("ntfs-3g \(installed.version)") else {
                throw EZError("NTFS-3G 版本检查未通过，请重新安装读写组件。")
            }
            return installed
        }
        let service = status(at: SystemDriver.serviceExecutable) {
            try MountServiceClient.check()
            return (SystemDriver.serviceExecutable.path, "已连接")
        }
        return DependencyReport(macFUSE: fuse, ntfs3g: driver, service: service, driverUsage: checkDriverUsage())
    }

    private static func status(at url: URL, probe: () throws -> (path: String, version: String)) -> DependencyStatus {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let result = try probe()
            return .ready(path: result.path, version: result.version)
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }
}
