import Darwin
import EzNTFSCore
import Foundation

@main
enum CLI {
    static func main() {
        do {
            try execute(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static func execute(_ args: [String]) throws {
        guard let command = args.first else { throw usage() }
        switch command {
        case "dependencies" where args.count == 1:
            let report = Dependencies.inspect()
            print("macFUSE\t\(report.macFUSE.summary)")
            print("NTFS-3G\t\(report.ntfs3g.summary)")
            print("挂载服务\t\(report.service.summary)")
        case "scan" where args.count == 1:
            for volume in try Disks.scan(known: RememberedDisks.load(preferences)) {
                print("\(volume.partition)\t\(volume.name)\t\(volume.mount?.kind ?? "unmounted")\t\(volume.isWritable ? "rw" : "ro")")
            }
        case "bind" where args.count == 2:
            try remember(Disks.volume(args[1], known: RememberedDisks.load(preferences)))
        case "bind-toshiba" where args.count == 1:
            // Older scripts supplied no device ID. Require a single candidate.
            let disks = try Disks.scan(known: RememberedDisks.load(preferences))
            guard disks.count == 1, let disk = disks.first else {
                throw EZError("请用 bind <设备编号> 指定一块外置 NTFS 硬盘。")
            }
            try remember(disk)
        case "mount" where args.count == 2:
            try MountServiceClient.mount(Disks.volume(args[1], known: RememberedDisks.load(preferences)))
            print("macFUSE 已确认读写挂载。")
        case "eject" where args.count == 2:
            try Disks.eject(Disks.volume(args[1], known: RememberedDisks.load(preferences)))
            print("系统已安全弹出。")
        case "copy" where args.count >= 4:
            let volume = try Disks.volume(args[1], known: RememberedDisks.load(preferences))
            let current = try Disks.copyMount(for: volume)
            let target = URL(fileURLWithPath: args[2], isDirectory: true)
            let sources = args.dropFirst(3).map { URL(fileURLWithPath: $0).standardizedFileURL }
            report(try VerifiedCopy.run(sources: sources, directory: target, expectedMount: current))
        case "verify-image" where args.count == 2:
            try verifyImage(URL(fileURLWithPath: args[1]))
        case "verify-image" where args.count == 4 && args[2] == "--driver":
            try verifyImage(URL(fileURLWithPath: args[1]), driver: args[3])
        default:
            throw usage()
        }
    }

    static var preferences: UserDefaults {
        let domain = "local.ezntfs.app"
        if Bundle.main.bundleIdentifier == domain { return .standard }
        return UserDefaults(suiteName: domain) ?? .standard
    }

    static func remember(_ volume: ExternalVolume) throws {
        guard volume.fingerprint.canRemember else { throw EZError("硬盘缺少稳定的设备标识，可以手动挂载。") }
        try RememberedDisks.save(RememberedDisks.load(preferences).union([volume.fingerprint]), to: preferences)
        print("已为「\(volume.name)」启用插盘自动挂载。")
    }

    static func usage() -> EZError {
        EZError("ezntfs-tool dependencies | scan | bind <设备编号> | mount <设备编号> | eject <设备编号> | copy <设备编号> <目标文件夹> <源...> | verify-image <临时镜像> [--driver <测试驱动>]")
    }

    static func report(_ receipt: CopyReceipt) {
        let speed = Double(receipt.bytes) / 1_048_576 / max(0.000001, receipt.writeSeconds)
        print("SHA-256 OK. files=\(receipt.files) bytes=\(receipt.bytes) write_s=\(receipt.writeSeconds) verify_s=\(receipt.verificationSeconds) MiB/s=\(speed)")
        print(receipt.destination.path)
    }

    static func verifyImage(_ source: URL, driver: String? = nil) throws {
        var details = stat()
        guard geteuid() != 0, lstat(source.path, &details) == 0, details.st_mode & S_IFMT == S_IFREG else {
            throw EZError("镜像测试必须由普通用户运行，并提供一个常规镜像文件。")
        }
        // Resolve the macOS temp root before comparing the kernel's mount path.
        let root = URL(fileURLWithPath: try canonicalPath(FileManager.default.temporaryDirectory.path), isDirectory: true)
            .appendingPathComponent("ezntfs-image-\(UUID().uuidString)", isDirectory: true)
        let mount = root.appendingPathComponent("mount", isDirectory: true)
        let fixtures = root.appendingPathComponent("sources", isDirectory: true)
        let image = root.appendingPathComponent("fixture.img")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let backing = try MountedDisk.at(root.path)
        defer {
            if let current = try? MountedDisk.at(mount.path), current == backing {
                try? FileManager.default.removeItem(at: root)
            }
        }
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: false)
        // NTFS mounting and test writes are confined to the private clone.
        _ = try Tool.run("/bin/cp", ["-c", source.path, image.path])
        guard lstat(image.path, &details) == 0, details.st_mode & S_IFMT == S_IFREG else {
            throw EZError("镜像副本不是普通文件。")
        }
        guard chmod(image.path, 0o600) == 0 else { throw EZError("无法设置私有镜像权限。") }
        func attach() throws {
            try Mounting.mountImage(source: image.path, destination: mount, label: "EZNTFS-TEST", driver: driver)
        }
        func detach() throws { _ = try Tool.run("/sbin/umount", [mount.path]) }
        defer {
            if let mounted = try? MountedDisk.at(mount.path), mounted.path == mount.path,
               mounted.source == (try? canonicalPath(image.path)) { try? detach() }
        }
        try attach()

        let payload = fixtures.appendingPathComponent("验证.bin")
        let directory = fixtures.appendingPathComponent("中文目录", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 ^ ($0 >> 8)) }).write(to: payload)
        for index in 0..<32 {
            try Data(repeating: UInt8(index), count: index * 137)
                .write(to: directory.appendingPathComponent("文件\(index).txt"))
        }
        let mounted = try MountedDisk.at(mount.path)
        let receipt = try VerifiedCopy.run(sources: [payload, directory], directory: mount, expectedMount: mounted)
        report(receipt)
        guard receipt.files == 33 else { throw EZError("镜像输出文件数量错误。") }

        let link = fixtures.appendingPathComponent("链接")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: payload)
        do {
            _ = try VerifiedCopy.run(sources: [link], directory: mount, expectedMount: mounted)
            throw EZError("符号链接用例意外通过。")
        } catch let error as EZError where error.message.starts(with: "无法复制") {
            print("unsupported symlink refused")
        }
        try detach()
        try attach()
        let recovered = receipt.destination.appendingPathComponent(payload.lastPathComponent)
        guard try Data(contentsOf: recovered) == Data(contentsOf: payload) else {
            throw EZError("重新挂载后副本与原件不一致。")
        }
        for index in 0..<32 {
            let file = receipt.destination.appendingPathComponent("中文目录/文件\(index).txt")
            guard try Data(contentsOf: file) == Data(repeating: UInt8(index), count: index * 137) else {
                throw EZError("重新挂载后发现不一致的文件。")
            }
        }
        try detach()
        print("33 synthetic files verified after remounting; the private image was safely unmounted.")
    }
}
