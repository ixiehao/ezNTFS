import Darwin
import Foundation

public enum Mounting {
    public static func privilegedMount(partition: String, connection: UInt64, deviceConnection: UInt64,
                                       fingerprint: DiskFingerprint, uid: UInt32, gid: UInt32) throws {
        guard geteuid() == 0, uid != 0 else { throw EZError("读写挂载需要 ezNTFS 系统服务。") }
        let candidate = try Disks.volume(partition, known: [fingerprint])
        guard candidate.connection == connection, candidate.deviceConnection == deviceConnection,
              candidate.fingerprint == fingerprint,
              candidate.testImageOwner == nil || candidate.testImageOwner == uid else {
            throw EZError("授权期间磁盘已变化，已取消操作。")
        }
        if candidate.isWritable { return }
        try checkMountCandidate(candidate)
        guard candidate.fileSystemConfirmed else { throw EZError("macOS 尚未确认该卷为 NTFS。") }
        let driver = try SystemDriver.requireDriver()

        // Dependency discovery runs an executable. Recheck the original connection before unmounting.
        let actual = try Disks.confirm(candidate)
        if actual.isWritable { return }
        try checkMountCandidate(actual)
        let restoreReadOnly = actual.mount != nil
        if restoreReadOnly {
            _ = try Tool.run(Disks.diskutil, ["unmount", "/dev/\(partition)"])
        }

        var staging: URL?
        do {
            let unmounted = try Disks.confirm(actual)
            guard unmounted.mount == nil else {
                throw EZError("系统没有释放只读卷。请稍后重试。")
            }
            let name = actual.name
            let usableName = name != "." && name != ".." && !name.isEmpty
                && !name.contains("/") && !name.contains(",") && !name.contains("\n")
            let label = usableName ? name : "ezNTFS"
            let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
            let preferred = volumes.appendingPathComponent(label, isDirectory: true)
            let destination = mkdir(preferred.path, 0o755) == 0
                ? preferred : volumes.appendingPathComponent("ezNTFS-\(UUID().uuidString.prefix(8))", isDirectory: true)
            if destination != preferred && mkdir(destination.path, 0o755) != 0 {
                throw posixError("创建挂载点")
            }
            staging = destination
            guard try Disks.confirm(actual).mount == nil else {
                throw EZError("系统在授权后重新挂载了卷，已取消本次操作。")
            }
            try startDriver(driver, source: "/dev/\(partition)", destination: destination, label: label,
                            uid: uid, gid: gid, partition: partition)
        } catch let mountError {
            if let staging { _ = rmdir(staging.path) }
            if restoreReadOnly, let stillConnected = try? Disks.confirm(actual), stillConnected.mount == nil {
                do {
                    _ = try Tool.run(Disks.diskutil, ["mount", "readOnly", "/dev/\(partition)"])
                } catch {
                    throw EZError("\(mountError.localizedDescription)\n未能恢复只读挂载：\(error.localizedDescription)")
                }
            }
            throw mountError
        }
    }

    public static func mountImage(source: String, destination: URL, label: String, driver: String? = nil) throws {
        guard geteuid() != 0 else { throw EZError("镜像测试只能由普通用户运行。") }
        if let driver {
            try startDriver(driver, source: source, destination: destination, label: label, uid: getuid(), gid: getgid())
        } else {
            try SystemDriver.withMountLock {
                try startDriver(SystemDriver.requireDriver(), source: source, destination: destination, label: label,
                                uid: getuid(), gid: getgid())
            }
        }
    }

    private static func startDriver(_ driver: String, source: String, destination: URL, label: String,
                                    uid: UInt32, gid: UInt32, partition: String? = nil) throws {
        guard !label.contains(","), !label.contains("\n") else { throw EZError("卷标包含不可用字符。") }
        let destinationPath = try canonicalPath(destination.path)
        let sourcePath = try canonicalPath(source)
        let options = ["local", "auto_xattr", "norecover", "windows_names", "noatime", "iosize=1048576",
                       "uid=\(uid)", "gid=\(gid)", "volname=\(label)"].joined(separator: ",")
        _ = try Tool.run(driver, ["-o", options, sourcePath, destinationPath])
        let deadline = DispatchTime.now() + .seconds(7)
        while DispatchTime.now() < deadline {
            if let observed = try? MountedDisk.at(destinationPath),
               matchesWritableMount(observed, source: sourcePath, path: destinationPath, partition: partition) {
                return
            }
            Thread.sleep(forTimeInterval: 0.12)
        }
        throw EZError("系统没有确认 NTFS 读写挂载。")
    }

    static func matchesWritableMount(_ observed: MountedDisk, source: String, path: String,
                                     partition: String?) -> Bool {
        guard observed.path == path, observed.kind == "macfuse", !observed.readOnly else { return false }
        if let partition { return observed.attached(to: partition) }
        return observed.source == source
    }

    private static func checkMountCandidate(_ volume: ExternalVolume) throws {
        guard volume.canMountReadWrite else {
            throw EZError("当前卷正由其他驱动接管，请先正常卸载再切换。")
        }
    }
}
