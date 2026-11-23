import CRemoveFile
import CryptoKit
import Darwin
import Foundation

public enum CopyStage: String, Sendable {
    case copying, checking
}

public struct CopyProgress: Sendable {
    public let name: String
    public let stage: CopyStage
    public let filesCompleted: Int
    public let fileCount: Int
    public let bytesDone: Int64
    public let fileBytes: Int64

    public init(name: String, stage: CopyStage, filesCompleted: Int, fileCount: Int,
                bytesDone: Int64, fileBytes: Int64) {
        self.name = name
        self.stage = stage
        self.filesCompleted = filesCompleted
        self.fileCount = fileCount
        self.bytesDone = bytesDone
        self.fileBytes = fileBytes
    }
}

public struct CopyReceipt: Sendable {
    public let destination: URL
    public let files: Int
    public let bytes: Int64
    public let writeSeconds: Double
    public let verificationSeconds: Double

    public init(destination: URL, files: Int, bytes: Int64, writeSeconds: Double, verificationSeconds: Double) {
        self.destination = destination
        self.files = files
        self.bytes = bytes
        self.writeSeconds = writeSeconds
        self.verificationSeconds = verificationSeconds
    }
}

public enum VerifiedCopy {
    private static let chunkSize = 1024 * 1024

    private struct Entry {
        let source: URL
        let parts: [String]
        let attributes: stat
        var isDirectory: Bool { attributes.st_mode & S_IFMT == S_IFDIR }
    }

    public static func run(sources: [URL], directory: URL, expectedMount: MountedDisk,
                           progress: @Sendable (CopyProgress) -> Void = { _ in }) throws -> CopyReceipt {
        guard !sources.isEmpty else { throw EZError("请选择要复制的文件或文件夹。") }
        guard !expectedMount.readOnly, expectedMount.kind == "macfuse",
              try MountedDisk.at(expectedMount.path) == expectedMount else {
            throw EZError("目标 NTFS 卷已离线或不可写。")
        }
        let target = URL(fileURLWithPath: try canonicalPath(directory.path), isDirectory: true)
        guard contains(target.path, within: expectedMount.path),
              try MountedDisk.at(target.path) == expectedMount else {
            throw EZError("请选择目标 NTFS 卷上的文件夹。")
        }

        var entries: [Entry] = []
        var names = Set<String>()
        for source in sources {
            let name = source.lastPathComponent
            guard !name.isEmpty && ![".", "..", "/"].contains(name) && names.insert(nameKey(name)).inserted else {
                throw EZError("有重复或无效的源文件名称。请在不同批次复制。")
            }
        }
        for source in sources {
            let name = source.lastPathComponent
            if let primary = companionKey(for: name), names.contains(primary) {
                throw EZError("所选项目含同名 AppleDouble 伴随文件 \(name)。请分别复制。")
            }
            try inventory(source, parts: [name], destination: target, entries: &entries)
        }
        let count = entries.reduce(0) { $0 + ($1.isDirectory ? 0 : 1) }
        let parentFD = open(target.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parentFD >= 0 else { throw posixError("打开目标文件夹") }
        defer { _ = close(parentFD) }
        var pinned = stat()
        guard fstat(parentFD, &pinned) == 0, pinned.st_dev == expectedMount.device else {
            throw EZError("目标设备已变化，已取消复制。")
        }
        let token = UUID().uuidString.lowercased()
        let staging = ".ezntfs-\(token).partial"
        guard mkdirat(parentFD, staging, 0o700) == 0 else { throw posixError("创建暂存目录") }
        let stageFD = openat(parentFD, staging, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard stageFD >= 0 else { throw posixError("打开暂存目录") }
        var committed = false
        defer {
            if !committed, sameDirectory(stageFD, at: parentFD, path: staging) {
                ezntfs_remove_partial_directory(parentFD, staging)
            }
            _ = close(stageFD)
        }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16_384)
        defer { buffer.deallocate() }
        var copied: [(index: Int, digest: SHA256.Digest)] = []
        copied.reserveCapacity(count)
        var bytes: Int64 = 0
        var writeSeconds = 0.0
        var verifySeconds = 0.0

        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            let relative = entry.parts.joined(separator: "/")
            if entry.isDirectory {
                guard mkdirat(stageFD, relative, 0o700) == 0 else { throw posixError("创建副本目录") }
                continue
            }
            let filesCompleted = copied.count
            let (digest, elapsed) = try writeFile(entry, relative: relative, stageFD: stageFD, buffer: buffer) { done in
                progress(CopyProgress(name: entry.source.lastPathComponent, stage: .copying,
                                      filesCompleted: filesCompleted, fileCount: count, bytesDone: done,
                                      fileBytes: entry.attributes.st_size))
            }
            copied.append((index, digest))
            writeSeconds += elapsed
            bytes += entry.attributes.st_size
        }

        // Finish metadata from children to parents, after creating all directory entries.
        for entry in entries.reversed() where entry.isDirectory {
            try Task.checkCancellation()
            try writeDirectoryMetadata(entry, stageFD: stageFD)
        }

        // On macFUSE, a later metadata write can create or change an AppleDouble file.
        // Verify the complete batch after all content and metadata writes have finished.
        var verified: [(parts: [String], attributes: stat)] = []
        verified.reserveCapacity(copied.count)
        for (index, file) in copied.enumerated() {
            try Task.checkCancellation()
            let entry = entries[file.index]
            let start = ProcessInfo.processInfo.systemUptime
            let attributes = try verifyFile(entry, digest: file.digest, stageFD: stageFD, buffer: buffer) { done in
                progress(CopyProgress(name: entry.source.lastPathComponent, stage: .checking, filesCompleted: index,
                                      fileCount: count, bytesDone: done, fileBytes: entry.attributes.st_size))
            }
            verified.append((entry.parts, attributes))
            verifySeconds += ProcessInfo.processInfo.systemUptime - start
        }
        for entry in entries {
            try Task.checkCancellation()
            var actual = stat()
            guard lstat(entry.source.path, &actual) == 0,
                  sameIdentity(actual, as: entry.attributes) else {
                throw EZError("源文件或文件夹在复制期间发生变化，副本没有交付。")
            }
        }
        for file in verified {
            try Task.checkCancellation()
            let path = file.parts.joined(separator: "/")
            var actual = stat()
            guard fstatat(stageFD, path, &actual, AT_SYMLINK_NOFOLLOW_ANY) == 0,
                  sameIdentity(actual, as: file.attributes) else {
                throw EZError("已校验的副本发生变化，副本没有交付。")
            }
        }
        try Task.checkCancellation()
        guard try MountedDisk.at(target.path) == expectedMount,
              sameDirectory(parentFD, at: AT_FDCWD, path: target.path),
              sameDirectory(stageFD, at: parentFD, path: staging) else {
            throw EZError("目标文件夹或卷在复制期间发生变化，副本没有交付。")
        }
        let date = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let published = "ezNTFS \(date) \(token.prefix(8))"
        try Task.checkCancellation()
        let destination = try publish(staging, as: published, parentFD: parentFD, target: target)
        committed = true
        return CopyReceipt(destination: destination, files: count, bytes: bytes,
                           writeSeconds: writeSeconds, verificationSeconds: verifySeconds)
    }

    private static func publish(_ staging: String, as name: String, parentFD: Int32, target: URL) throws -> URL {
        let folder = target.appendingPathComponent(name, isDirectory: true)
        if renameatx_np(parentFD, staging, parentFD, name, UInt32(RENAME_EXCL)) == 0 { return folder }
        let error = errno
        guard error == ENOSYS || error == ENOTSUP else {
            throw posixError("以不覆盖方式提交已校验副本")
        }
        // macFUSE may lack RENAME_EXCL. Reserve a new outer directory exclusively;
        // plain rename is confined to that directory, and can never replace an existing file.
        guard mkdirat(parentFD, name, 0o700) == 0 else { throw posixError("独占创建结果文件夹") }
        var published = false
        defer { if !published { _ = unlinkat(parentFD, name, AT_REMOVEDIR) } }
        let resultFD = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard resultFD >= 0 else { throw posixError("打开结果文件夹") }
        defer { _ = close(resultFD) }
        let child = "已校验文件"
        var existing = stat()
        guard fstatat(resultFD, child, &existing, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT,
              renameat(parentFD, staging, resultFD, child) == 0 else { throw posixError("移入已校验副本") }
        published = true
        return folder.appendingPathComponent(child, isDirectory: true)
    }

    private static func contains(_ path: String, within root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func sameDirectory(_ fd: Int32, at parentFD: Int32, path: String) -> Bool {
        var opened = stat()
        var named = stat()
        return fstat(fd, &opened) == 0 && fstatat(parentFD, path, &named, AT_SYMLINK_NOFOLLOW) == 0
            && named.st_mode & S_IFMT == S_IFDIR && opened.st_dev == named.st_dev && opened.st_ino == named.st_ino
    }

    private static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func companionKey(for name: String) -> String? {
        name.hasPrefix("._") ? nameKey(String(name.dropFirst(2))) : nil
    }

    private static func inventory(_ source: URL, parts: [String], destination: URL,
                                  entries: inout [Entry]) throws {
        try Task.checkCancellation()
        var attributes = stat()
        guard lstat(source.path, &attributes) == 0 else { throw posixError("读取源文件") }
        let mode = attributes.st_mode & S_IFMT
        guard mode == S_IFREG || mode == S_IFDIR else {
            throw EZError("无法复制 \(source.lastPathComponent)。请选择普通文件或文件夹。")
        }
        if mode == S_IFDIR, contains(destination.path, within: try canonicalPath(source.path)) {
            throw EZError("目标文件夹位于所选源文件夹内。")
        }
        entries.append(Entry(source: source, parts: parts, attributes: attributes))
        if mode == S_IFDIR {
            for name in try directoryNames(source.path) {
                try inventory(source.appendingPathComponent(name), parts: parts + [name],
                              destination: destination, entries: &entries)
            }
            var actual = stat()
            guard lstat(source.path, &actual) == 0, sameIdentity(actual, as: attributes) else {
                throw EZError("源文件夹在清点期间发生变化。")
            }
        }
    }

    private static func directoryNames(_ path: String) throws -> [String] {
        // Foundation's directory enumeration hides literal files beginning with "._".
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw posixError("打开源文件夹") }
        guard let directory = fdopendir(fd) else {
            let error = posixError("读取源文件夹")
            _ = close(fd)
            throw error
        }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let item = readdir(directory) else {
                if errno != 0 { throw posixError("枚举源文件夹") }
                break
            }
            let name = withUnsafeBytes(of: item.pointee.d_name) {
                String(bytes: $0.prefix(while: { $0 != 0 }), encoding: .utf8)
            }
            guard let name else { throw EZError("源文件夹包含无法识别的文件名。") }
            if name != "." && name != ".." { names.append(name) }
        }

        var byKey: [String: String] = [:]
        for name in names {
            guard byKey.updateValue(name, forKey: nameKey(name)) == nil else {
                throw EZError("源文件夹包含名称冲突的项目。")
            }
        }
        let hasCompanions = names.contains { name in
            companionKey(for: name).map { byKey[$0] != nil } ?? false
        }
        let sourceUsesAppleDouble = hasCompanions && (try? MountedDisk.at(path).kind) == "macfuse"
        return try names.sorted().filter { name in
            guard let key = companionKey(for: name), let companion = byKey[key] else { return true }
            // A genuine companion is serialized by macOS from the primary file's xattrs.
            if sourceUsesAppleDouble, isAppleDouble(fd, name: name) {
                let source = openat(fd, companion, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                if source >= 0 {
                    defer { _ = close(source) }
                    var info = stat()
                    if fstat(source, &info) == 0,
                       [S_IFREG, S_IFDIR].contains(info.st_mode & S_IFMT),
                       flistxattr(source, nil, 0, 0) > 0 { return false }
                }
            }
            throw EZError("源文件夹中的 \(name) 与 \(companion) 存在元数据文件名冲突。请分别复制。")
        }
    }

    private static func isAppleDouble(_ directory: Int32, name: String) -> Bool {
        let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { return false }
        defer { _ = close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        var header = [UInt8](repeating: 0, count: 26)
        let count = header.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
        guard count == header.count, header.prefix(8).elementsEqual([0, 5, 22, 7, 0, 2, 0, 0]) else { return false }
        let entries = Int(header[24]) * 256 + Int(header[25])
        let tableBytes = entries * 12
        let dataStart = 26 + tableBytes
        guard entries > 0, info.st_size >= Int64(dataStart) else { return false }
        var table = [UInt8](repeating: 0, count: tableBytes)
        let tableRead = table.withUnsafeMutableBytes { pread(file, $0.baseAddress, $0.count, 26) }
        guard tableRead == tableBytes else { return false }

        func field(at index: Int) -> Int64 {
            table[index..<(index + 4)].reduce(0) { ($0 << 8) | Int64($1) }
        }

        return stride(from: 0, to: tableBytes, by: 12).allSatisfy { entry in
            let offset = field(at: entry + 4)
            let length = field(at: entry + 8)
            return offset >= Int64(dataStart) && offset + length <= info.st_size
        }
    }

    private static func writeDirectoryMetadata(_ entry: Entry, stageFD: Int32) throws {
        let input = open(entry.source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard input >= 0 else { throw posixError("打开源文件夹") }
        defer { _ = close(input) }
        var observed = stat()
        guard fstat(input, &observed) == 0, sameIdentity(observed, as: entry.attributes) else {
            throw EZError("源文件夹在复制期间发生变化。")
        }
        let output = openat(stageFD, entry.parts.joined(separator: "/"), O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY)
        guard output >= 0 else { throw posixError("打开副本文件夹") }
        defer { _ = close(output) }
        try copyExtendedAttributes(input, to: output)
        var timestamps = [entry.attributes.st_atimespec, entry.attributes.st_mtimespec]
        guard futimens(output, &timestamps) == 0 else { throw posixError("保留文件夹日期") }
        guard fsync(output) == 0 else { throw posixError("同步副本文件夹") }
    }

    private static func copyExtendedAttributes(_ input: Int32, to output: Int32) throws {
        guard flistxattr(input, nil, 0, 0) == 0
            || fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_XATTR)) == 0 else {
            throw posixError("复制扩展属性")
        }
    }

    private static func writeFile(
        _ entry: Entry, relative: String, stageFD: Int32, buffer: UnsafeMutableRawPointer, report: (Int64) -> Void
    ) throws -> (SHA256.Digest, Double) {
        let input = open(entry.source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw posixError("打开源文件") }
        defer { _ = close(input) }
        guard sameFile(input, as: entry.attributes) else { throw EZError("源文件已变化。") }
        let output = openat(stageFD, relative, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_ANY, 0o600)
        guard output >= 0 else { throw posixError("新建副本文件") }
        let start = ProcessInfo.processInfo.systemUptime
        let hash: SHA256.Digest
        do {
            hash = try readAndHash(input, output: output, expectedBytes: entry.attributes.st_size,
                                   buffer: buffer, report: report)
            try Task.checkCancellation()
            guard sameFile(input, as: entry.attributes) else { throw EZError("源文件在复制期间有改动。") }
            var timestamps = [entry.attributes.st_atimespec, entry.attributes.st_mtimespec]
            guard futimens(output, &timestamps) == 0 else { throw posixError("保留文件日期") }
            try copyExtendedAttributes(input, to: output)
            guard sameFile(input, as: entry.attributes) else { throw EZError("源文件在复制期间有改动。") }
            guard fsync(output) == 0 else { throw posixError("同步副本") }
        } catch {
            _ = close(output)
            throw error
        }
        guard close(output) == 0 else { throw posixError("关闭副本") }
        return (hash, ProcessInfo.processInfo.systemUptime - start)
    }

    private static func verifyFile(
        _ entry: Entry, digest: SHA256.Digest, stageFD: Int32, buffer: UnsafeMutableRawPointer, report: (Int64) -> Void
    ) throws -> stat {
        let verification = openat(stageFD, entry.parts.joined(separator: "/"), O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard verification >= 0 else { throw posixError("重新打开副本") }
        defer { _ = close(verification) }
        var observed = stat()
        guard fstat(verification, &observed) == 0, observed.st_mode & S_IFMT == S_IFREG,
              observed.st_size == entry.attributes.st_size else {
            throw EZError("\(entry.source.lastPathComponent) 的副本大小或类型有变化。")
        }
        _ = fcntl(verification, F_NOCACHE, 1)
        guard try readAndHash(verification, output: nil, expectedBytes: observed.st_size,
                              buffer: buffer, report: report) == digest,
              sameFile(verification, as: observed) else {
            throw EZError("\(entry.source.lastPathComponent) 的 SHA-256 校验失败。")
        }
        return observed
    }

    private static func sameIdentity(_ actual: stat, as previous: stat) -> Bool {
        actual.st_mode & S_IFMT == previous.st_mode & S_IFMT
            && actual.st_dev == previous.st_dev && actual.st_ino == previous.st_ino
            && actual.st_size == previous.st_size
            && actual.st_mtimespec.tv_sec == previous.st_mtimespec.tv_sec
            && actual.st_mtimespec.tv_nsec == previous.st_mtimespec.tv_nsec
            && actual.st_ctimespec.tv_sec == previous.st_ctimespec.tv_sec
            && actual.st_ctimespec.tv_nsec == previous.st_ctimespec.tv_nsec
    }

    private static func sameFile(_ fd: Int32, as previous: stat) -> Bool {
        var actual = stat()
        return fstat(fd, &actual) == 0 && actual.st_mode & S_IFMT == S_IFREG
            && sameIdentity(actual, as: previous)
    }

    private static func readAndHash(_ input: Int32, output: Int32?, expectedBytes: Int64,
                                    buffer: UnsafeMutableRawPointer, report: (Int64) -> Void) throws -> SHA256.Digest {
        var digest = SHA256()
        var bytes: Int64 = 0
        var lastReport = ProcessInfo.processInfo.systemUptime
        report(0)
        while bytes < expectedBytes {
            try Task.checkCancellation()
            let requested = Int(min(Int64(chunkSize), expectedBytes - bytes))
            let count = read(input, buffer, requested)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError("读取文件")
            }
            guard count > 0 else { throw EZError("文件在读取结束前被截短。") }
            digest.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            if let output {
                var consumed = 0
                while consumed < count {
                    let written = write(output, buffer + consumed, count - consumed)
                    if written < 0 && errno == EINTR { continue }
                    guard written >= 0 else { throw posixError("写入临时副本") }
                    guard written > 0 else { throw EZError("写入临时副本时没有进展。") }
                    consumed += written
                }
            }
            bytes += Int64(count)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastReport >= 0.15 {
                report(bytes)
                lastReport = now
            }
        }
        report(bytes)
        return digest.finalize()
    }
}
