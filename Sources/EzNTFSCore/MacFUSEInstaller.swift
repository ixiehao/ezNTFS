import CryptoKit
import Darwin
import Foundation

public enum MacFUSEInstaller {
    public static let version = "5.5.0"
    public static let releasePage = URL(string: "https://github.com/macfuse/macfuse/releases/tag/macfuse-\(version)")!
    static let imageSHA256 = "92c21ef2db4199bcf5bddc8e6efb57b23ecb9715f74ab38cba2c77ab226d3830"
    private static let imageSize = 22_946_514
    private static let librarySHA256 = "6ffcc5453d9a4e8ac006af2b40d4c7aaf94637b735d581f501c0a780b89b3ad5"

    public enum PreparationError: LocalizedError {
        case download, verification
    }

    public enum Source: CaseIterable, Equatable, Sendable {
        case official, tsinghua, nanjing

        var url: URL {
            let directory = switch self {
            case .official: "https://github.com/macfuse/macfuse/releases/download/macfuse-\(MacFUSEInstaller.version)"
            case .tsinghua: "https://mirrors.tuna.tsinghua.edu.cn/macports/distfiles/macfuse"
            case .nanjing: "https://mirror.nju.edu.cn/macports/distfiles/macfuse"
            }
            return URL(string: "\(directory)/macfuse-\(MacFUSEInstaller.version).dmg")!
        }
    }

    public static func prepare(reporting: @Sendable (Source) async -> Void = { _ in }) async throws -> URL {
        let image = try await downloadImage(reporting: reporting)
        defer { try? FileManager.default.removeItem(at: image) }
        try Task.checkCancellation()
        return try extractVerifiedImage(from: image)
    }

    // An attempt returns an owned temporary file. Failed or cancelled attempts release it here.
    static func downloadImage(reporting: @Sendable (Source) async -> Void = { _ in },
                              attempt: (Source) async throws -> URL = download) async throws -> URL {
        var invalidImage = false
        for source in Source.allCases {
            try Task.checkCancellation()
            await reporting(source)
            try Task.checkCancellation()
            let image: URL
            do {
                image = try await attempt(source)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                continue
            }
            do {
                try Task.checkCancellation()
                try verifyImage(image)
                return image
            } catch {
                try? FileManager.default.removeItem(at: image)
                if error is CancellationError { throw error }
                invalidImage = true
            }
        }
        throw invalidImage ? PreparationError.verification : PreparationError.download
    }

    static func download(_ source: Source) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = source == .official ? 30 : 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (image, response) = try await session.download(from: source.url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https" else {
            try? FileManager.default.removeItem(at: image)
            throw PreparationError.download
        }
        return image
    }

    static func extract(from image: URL) throws -> URL {
        try verifyImage(image)
        return try extractVerifiedImage(from: image)
    }

    private static func verifyImage(_ image: URL) throws {
        guard let values = try? image.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, values.fileSize == imageSize,
              try digest(Data(contentsOf: image, options: .mappedIfSafe)) == imageSHA256 else {
            throw PreparationError.verification
        }
    }

    private static func extractVerifiedImage(from image: URL) throws -> URL {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("ezntfs-macfuse-\(UUID().uuidString)")
        let mount = directory.appendingPathComponent("Image")
        let installer = directory.appendingPathComponent("Install macFUSE.pkg")
        try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        var keepInstaller = false
        var imageMounted = false
        defer {
            // Never remove the temporary directory while it still contains a mount.
            if !keepInstaller && !imageMounted { try? files.removeItem(at: directory) }
        }
        try files.createDirectory(at: mount, withIntermediateDirectories: false)
        _ = try Tool.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noautoopen",
                                             "-mountpoint", mount.path, image.path])
        imageMounted = true
        defer {
            if imageMounted, (try? Tool.run("/usr/bin/hdiutil", ["detach", mount.path])) != nil { imageMounted = false }
        }
        let package = mount.appendingPathComponent(installer.lastPathComponent)
        guard try package.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try package.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false else {
            throw PreparationError.verification
        }
        try files.copyItem(at: package, to: installer)
        _ = try Tool.run("/usr/bin/hdiutil", ["detach", mount.path])
        imageMounted = false
        let signature = try Tool.run("/usr/sbin/pkgutil", ["--check-signature", installer.path],
                                     queryTimeout: 20, environment: ["LC_ALL": "C"])
        guard isVendorSignature(String(decoding: signature, as: UTF8.self)) else {
            throw PreparationError.verification
        }
        keepInstaller = true
        return installer
    }

    static func isVendorSignature(_ signature: String) -> Bool {
        signature.contains("Status: signed by a developer certificate issued by Apple for distribution")
            && signature.split(whereSeparator: \.isNewline).contains {
                $0.range(of: #"\A\s*1\. Developer ID Installer: .+ \(3T5GSNBU6W\)\s*\z"#,
                         options: .regularExpression) != nil
            }
    }

    static func checkInstalledLibrary() throws {
        let path = "/usr/local/lib/libfuse.2.dylib"
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw EZError("libfuse.2.dylib: \(path)") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              (1...5_000_000).contains(attributes.st_size),
              let data = try handle.read(upToCount: Int(attributes.st_size) + 1),
              data.count == Int(attributes.st_size), digest(data) == librarySHA256 else {
            throw EZError("libfuse.2.dylib: SHA-256")
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
