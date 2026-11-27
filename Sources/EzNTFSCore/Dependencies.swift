import Foundation

public enum DependencyStatus: Equatable, Sendable {
    case missing
    case unavailable(String)
    case disabled
    case ready(path: String, version: String)

    public var path: String? {
        if case .ready(let path, _) = self { return path }
        return nil
    }

    public var summary: String {
        switch self {
        case .missing: "未安装"
        case .disabled: "已停用"
        case .unavailable(let cause): cause
        case .ready(_, let version): version
        }
    }
}

public enum DependencyInstallStep: Equatable, Sendable {
    case macFUSE
    case mainInstaller
    case driverRepair
    case serviceSettings
}

public struct DependencyReport: Equatable, Sendable {
    public let macFUSE: DependencyStatus
    public let ntfs3g: DependencyStatus
    public let service: DependencyStatus
    public init(macFUSE: DependencyStatus, ntfs3g: DependencyStatus, service: DependencyStatus) {
        self.macFUSE = macFUSE
        self.ntfs3g = ntfs3g
        self.service = service
    }

    public var canMountReadWrite: Bool { macFUSE.path != nil && ntfs3g.path != nil && service.path != nil }

    public func installStep(needsMainInstall: Bool = false) -> DependencyInstallStep? {
        if macFUSE.path == nil { return .macFUSE }
        if needsMainInstall || service == .missing { return .mainInstaller }
        if case .unavailable = service { return .mainInstaller }
        if service == .disabled { return .serviceSettings }
        if ntfs3g.path == nil { return .driverRepair }
        return nil
    }
}

public enum Dependencies {
    public static let cachedInstaller = SystemDriver.support.appendingPathComponent("ezNTFS-Reinstall.pkg")
    public static let installedApp = URL(fileURLWithPath: "/Applications/ezNTFS.app", isDirectory: true)

    public static func installationUsage() -> DriverUsage {
        DriverUsage.inspectInstallation(under: SystemDriver.driverReceipt.deletingLastPathComponent().path)
    }

    public static func needsInstallation(build: String) -> Bool {
        guard FileManager.default.fileExists(atPath: installedApp.appendingPathComponent("Contents/MacOS/ezNTFS").path),
              let installedBuild = (try? MountServiceConfiguration.Identity.load())?.appBuild else {
            return true
        }
        return installedBuild.compare(build, options: .numeric) == .orderedAscending
    }

    public static func inspect(fromSetup: Bool = false) -> DependencyReport {
        let fuse = status(at: SystemDriver.fuseBundle) {
            let version = try SystemDriver.inspectFUSE()
            guard version == MacFUSEInstaller.version else {
                throw EZError("macFUSE \(version) · Required / 需要 \(MacFUSEInstaller.version)")
            }
            try MacFUSEInstaller.checkInstalledLibrary()
            return (SystemDriver.fuseBundle.path, version)
        }
        let driver = status(at: SystemDriver.driverReceipt) {
            let installed = try SystemDriver.inspectDriver()
            let output = try Tool.run(installed.path, ["--version"], queryTimeout: 5, includeStandardError: true)
            guard String(decoding: output, as: UTF8.self).contains("ntfs-3g \(installed.version)") else {
                throw EZError("NTFS-3G 版本检查未通过，请重新安装读写组件。")
            }
            return installed
        }
        let service = inspectService(fromSetup: fromSetup)
        return DependencyReport(macFUSE: fuse, ntfs3g: driver, service: service)
    }

    private static func inspectService(fromSetup: Bool) -> DependencyStatus {
        let executable = SystemDriver.serviceExecutable
        guard FileManager.default.fileExists(atPath: executable.path) else { return .missing }
        do {
            let identity = try MountServiceConfiguration.Identity.load()
            try SystemDriver.verifyCode(at: executable, requirement: identity.serviceRequirement)
            let job = URL(fileURLWithPath: "/Library/LaunchDaemons/\(MountServiceConfiguration.name).plist")
            try SystemDriver.protectedPath(job)
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: job), format: nil)
            guard let jobInfo = plist as? [String: Any],
                  jobInfo["Label"] as? String == MountServiceConfiguration.name,
                  jobInfo["ProgramArguments"] as? [String] == [executable.path],
                  let services = jobInfo["MachServices"] as? [String: Bool],
                  services[MountServiceConfiguration.name] == true else {
                throw EZError("挂载服务配置不完整，请运行 ezNTFS 安装器。")
            }
            let disabled = try? Tool.run("/bin/launchctl", ["print-disabled", "system"], queryTimeout: 3)
            if let disabled, isServiceDisabled(String(decoding: disabled, as: UTF8.self)) { return .disabled }
            if fromSetup {
                // The installed app probes XPC on launch using its pinned client signature.
                _ = try Tool.run("/bin/launchctl", ["print", "system/\(MountServiceConfiguration.name)"], queryTimeout: 3)
            } else {
                try MountServiceClient.check()
            }
            return .ready(path: executable.path, version: "已连接")
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func isServiceDisabled(_ listing: String) -> Bool {
        listing.split(whereSeparator: \.isNewline).contains {
            $0.range(of: #"\A\s*"local\.ezntfs\.mount"\s*=>\s*(disabled|true)\s*,?\s*\z"#,
                     options: .regularExpression) != nil
        }
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
