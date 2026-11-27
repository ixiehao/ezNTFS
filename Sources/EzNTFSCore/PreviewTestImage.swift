#if EZNTFS_MONTEREY_PREVIEW
import Darwin
import Foundation

public struct PreviewTestImage: Sendable {
    private static let imageName = "EZNTFS-QA.img"
    private static let imageSize = 64 * 1024 * 1024
    private static let sampleName = "ezNTFS Test.txt"
    private static let sample = Data(String(repeating: "ezNTFS · NTFS read/write test\n", count: 64).utf8)
    private let directory: URL

    public init(directory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Application Support/ezNTFS/NTFS Test", isDirectory: true)) {
        self.directory = directory
    }

    var image: URL { directory.appendingPathComponent(Self.imageName) }

    public var fingerprint: DiskFingerprint? { Self.identity(of: image)?.fingerprint }

    public func connect(template: URL) throws -> ExternalVolume {
        try prepare(template: template)
        guard let fingerprint else { throw EZError("The test image could not be identified.") }
        if let existing = try attachedVolume(fingerprint) { return existing }

        _ = try Tool.run("/usr/bin/hdiutil", ["attach", "-readwrite", "-nobrowse", "-noautoopen", image.path],
                         queryTimeout: 25)
        let deadline = DispatchTime.now() + .seconds(8)
        repeat {
            if let volume = try attachedVolume(fingerprint) { return volume }
            Thread.sleep(forTimeInterval: 0.12)
        } while DispatchTime.now() < deadline
        throw EZError("macOS has not reported the test NTFS volume.")
    }

    public func writeSample(to volume: ExternalVolume) throws -> String {
        try Self.writeSample(to: writableMount(for: volume))
    }

    static func writeSample(to mount: MountedDisk) throws -> String {
        let sourceFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ezntfs-sample-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: sourceFolder) }
        let source = sourceFolder.appendingPathComponent(Self.sampleName)
        try Self.sample.write(to: source)
        let receipt = try VerifiedCopy.run(sources: [source],
                                           directory: URL(fileURLWithPath: mount.path, isDirectory: true),
                                           expectedMount: mount)
        return String(receipt.destination.path.dropFirst(mount.path.count + 1))
    }

    public func verifySample(in batch: String, on volume: ExternalVolume) throws {
        let mount = try writableMount(for: volume)
        try Self.verifySample(in: batch, on: mount)
        guard try writableMount(for: volume) == mount else {
            throw EZError("The test volume changed during verification.")
        }
    }

    static func verifySample(in batch: String, on mount: MountedDisk) throws {
        let root = open(mount.path, O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard root >= 0 else { throw posixError("Open test volume") }
        defer { close(root) }
        var info = stat()
        guard fstat(root, &info) == 0, info.st_dev == mount.device else {
            throw EZError("The test volume changed during verification.")
        }
        let parts = batch.split(separator: "/", omittingEmptySubsequences: false)
        guard let first = parts.first, first.hasPrefix("ezNTFS "),
              parts.count == 1 || (parts.count == 2 && parts[1] == "已校验文件") else {
            throw EZError("Invalid test batch name.")
        }
        let folder = openat(root, String(first), O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard folder >= 0 else { throw posixError("Open the previous test batch") }
        defer { close(folder) }
        let output = parts.count == 1 ? folder
            : openat(folder, String(parts[1]), O_RDONLY | O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW)
        guard output >= 0 else { throw posixError("Open the verified test batch") }
        defer { if output != folder { close(output) } }
        let sample = openat(output, Self.sampleName, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard sample >= 0 else { throw posixError("Read the previous test file") }
        let handle = FileHandle(fileDescriptor: sample, closeOnDealloc: true)
        guard fstat(sample, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_dev == mount.device, info.st_size == Self.sample.count,
              try handle.read(upToCount: Self.sample.count + 1) == Self.sample,
              try MountedDisk.at(mount.path) == mount else {
            throw EZError("The previous test file did not match.")
        }
    }

    private func writableMount(for volume: ExternalVolume) throws -> MountedDisk {
        guard volume.testImageOwner == geteuid(), fingerprint == volume.fingerprint else {
            throw EZError("The test image changed. Connect it again before testing.")
        }
        return try Disks.copyMount(for: volume)
    }

    private func attachedVolume(_ identity: DiskFingerprint) throws -> ExternalVolume? {
        try Disks.scan(known: [identity]).first { $0.fingerprint == identity }
    }

    private func prepare(template: URL) throws {
        let files = FileManager.default
        var info = stat()
        if lstat(directory.path, &info) != 0, errno == ENOENT {
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        }
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw EZError("The test image directory must be private and owned by the current user.")
        }
        if lstat(image.path, &info) == 0 {
            guard fingerprint != nil else { throw EZError("The existing test image is not a private NTFS fixture.") }
            return
        }
        guard errno == ENOENT else { throw posixError("Check the test image") }

        let contents = try Tool.run("/usr/bin/gzip", ["-dc", template.path], queryTimeout: 20)
        guard contents.count == Self.imageSize, contents[3..<11] == Data("NTFS    ".utf8) else {
            throw EZError("The bundled NTFS test image is invalid.")
        }
        let staging = directory.appendingPathComponent(UUID().uuidString)
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        let output = staging.appendingPathComponent(Self.imageName)
        try contents.write(to: output)
        guard chmod(output.path, 0o600) == 0 else { throw posixError("Protect the test image") }
        if renamex_np(output.path, image.path, UInt32(RENAME_EXCL)) != 0, errno != EEXIST {
            throw posixError("Save the test image")
        }
    }

    static func identity(of image: URL) -> (fingerprint: DiskFingerprint, owner: uid_t)? {
        guard image.lastPathComponent == imageName else { return nil }
        var info = stat()
        guard lstat(image.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid != 0, info.st_mode & 0o077 == 0, info.st_size > 0,
              geteuid() == 0 || info.st_uid == geteuid() else { return nil }
        let fingerprint = DiskFingerprint(serial: "image:\(info.st_dev):\(info.st_ino)", vendor: 0, product: 0,
                                          partitionOffset: 0, partitionBytes: UInt64(info.st_size))
        return (fingerprint, info.st_uid)
    }
}
#endif
