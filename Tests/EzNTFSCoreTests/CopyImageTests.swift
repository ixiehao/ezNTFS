import Darwin
import EzNTFSCore
import Foundation
import Testing

@Suite(.serialized)
struct CopyImageTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZNTFS_TEST_IMAGE"] != nil))
    func copyRemountAndMutationRegression() async throws {
        let fixture = try #require(ProcessInfo.processInfo.environment["EZNTFS_TEST_IMAGE"])
        let base = URL(fileURLWithPath: try canonicalPath(FileManager.default.temporaryDirectory.path),
                       isDirectory: true)
        let root = base.appendingPathComponent("ezntfs-qa-" + UUID().uuidString, isDirectory: true)
        let target = root.appendingPathComponent("mount", isDirectory: true)
        let image = root.appendingPathComponent("fixture.img")
        let source = root.appendingPathComponent("source", isDirectory: true)
        let fs = FileManager.default
        try fs.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backing = try MountedDisk.at(root.path)
        defer {
            do {
                try unmountTestImage(image, at: target, backing: backing)
                try fs.removeItem(at: root)
            } catch { Issue.record("Temporary image cleanup failed at \(root.path): \(error.localizedDescription)") }
        }
        try fs.createDirectory(at: source, withIntermediateDirectories: false)
        _ = try Tool.run("/bin/cp", ["-c", fixture, image.path])
        func attach() throws {
            try Mounting.mountImage(source: image.path, destination: target, label: "EZNTFS-QA",
                                    driver: ProcessInfo.processInfo.environment["EZNTFS_TEST_DRIVER"])
        }
        try attach()
        let mounted = try MountedDisk.at(target.path)

        let primary = source.appendingPathComponent("测试.txt")
        let orphan = source.appendingPathComponent("._独立文件")
        let collision = source.appendingPathComponent("._测试.txt")
        let data = Data(repeating: 65, count: 2 * 1_048_576 + 8192)
        try data.write(to: primary)
        try Data("literal file".utf8).write(to: orphan)
        _ = try Tool.run("/usr/bin/xattr", ["-w", "com.ezntfs.fixture", "metadata", primary.path])

        let first = try VerifiedCopy.run(sources: [source], directory: target, expectedMount: mounted)
        #expect(first.files == 2)
        let second = try VerifiedCopy.run(sources: [first.destination.appendingPathComponent("source")],
                                          directory: target, expectedMount: mounted)
        #expect(second.files == 2)

        // An APFS companion can describe unrelated metadata even if its header is valid.
        let genuine = first.destination.appendingPathComponent("source/._测试.txt")
        try Data(contentsOf: genuine).write(to: collision)
        #expect(throws: EZError.self) {
            try VerifiedCopy.run(sources: [source], directory: target, expectedMount: mounted)
        }

        // macFUSE exposes the genuine sidecar as metadata; a literal collision must be rejected.
        try Data("literal collision".utf8).write(to: collision)
        for inputs in [[source], [collision, primary]] {
            #expect(throws: EZError.self) {
                try VerifiedCopy.run(sources: inputs, directory: target, expectedMount: mounted)
            }
        }
        try fs.removeItem(at: collision)

        let mutated = await Task.detached {
            try VerifiedCopy.run(sources: [primary], directory: target, expectedMount: mounted) { progress in
                guard progress.stage == .copying, progress.bytesDone == 0 else { return }
                do {
                    let handle = try FileHandle(forUpdating: primary)
                    defer { try? handle.close() }
                    var info = stat()
                    guard fstat(handle.fileDescriptor, &info) == 0 else { throw EZError("fstat") }
                    try handle.write(contentsOf: Data([66]))
                    var dates = [info.st_atimespec, info.st_mtimespec]
                    guard futimens(handle.fileDescriptor, &dates) == 0 else { throw EZError("futimens") }
                } catch { Issue.record("Fixture mutation failed: \(error)") }
            }
        }.result
        if case .success = mutated { Issue.record("Copy accepted a changed source with restored mtime.") }

        let shortSource = root.appendingPathComponent("truncated.bin")
        try data.write(to: shortSource)
        let shortTarget = target.appendingPathComponent("truncated")
        try fs.createDirectory(at: shortTarget, withIntermediateDirectories: false)
        #expect(throws: EZError.self) {
            try VerifiedCopy.run(sources: [shortSource], directory: shortTarget, expectedMount: mounted) { progress in
                guard progress.stage == .copying, progress.bytesDone == 0 else { return }
                do {
                    let handle = try FileHandle(forWritingTo: shortSource)
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: 512)
                } catch { Issue.record("Fixture truncation failed: \(error)") }
            }
        }
        #expect(try fs.contentsOfDirectory(atPath: shortTarget.path).isEmpty)

        for cancel in [false, true] {
            let directory = target.appendingPathComponent(cancel ? "cancel" : "continue")
            let displaced = directory.appendingPathExtension("moved")
            try fs.createDirectory(at: directory, withIntermediateDirectories: false)
            let moved = await Task.detached {
                try VerifiedCopy.run(sources: [primary], directory: directory, expectedMount: mounted) { progress in
                    guard progress.stage == .copying, progress.bytesDone == 0 else { return }
                    do {
                        let fs = FileManager()
                        let staging = try #require(fs.contentsOfDirectory(atPath: directory.path).first)
                        try fs.moveItem(at: directory, to: displaced)
                        let replacement = directory.appendingPathComponent(staging, isDirectory: true)
                        try fs.createDirectory(at: replacement, withIntermediateDirectories: true)
                        try data.write(to: replacement.appendingPathComponent("keep"))
                        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                    } catch { Issue.record("Fixture move failed: \(error)") }
                }
            }.result
            switch moved {
            case .success: Issue.record("Copy succeeded after its destination directory moved.")
            case .failure(let error): #expect((error is CancellationError) == cancel)
            }
            let replacement = try #require(fs.contentsOfDirectory(atPath: directory.path).first)
            let keptFile = directory.appendingPathComponent(replacement).appendingPathComponent("keep")
            #expect(try Data(contentsOf: keptFile) == data)
            #expect(try fs.contentsOfDirectory(atPath: displaced.path).isEmpty)
        }

        let later = source.appendingPathComponent("last")
        try Data([1, 2, 3]).write(to: later)
        let corruptTarget = target.appendingPathComponent("corruption")
        try fs.createDirectory(at: corruptTarget, withIntermediateDirectories: false)
        #expect(throws: EZError.self) {
            try VerifiedCopy.run(sources: [primary, later], directory: corruptTarget, expectedMount: mounted) { progress in
                guard progress.stage == .copying, progress.name == later.lastPathComponent, progress.bytesDone == 0 else { return }
                do {
                    let staging = try #require(FileManager().contentsOfDirectory(atPath: corruptTarget.path).first)
                    let file = corruptTarget.appendingPathComponent(staging).appendingPathComponent(primary.lastPathComponent)
                    let handle = try FileHandle(forUpdating: file)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: 1)
                    try handle.write(contentsOf: Data([67]))
                } catch { Issue.record("Fixture corruption failed: \(error)") }
            }
        }
        #expect(try fs.contentsOfDirectory(atPath: corruptTarget.path).isEmpty)

        let changedSource = root.appendingPathComponent("changed-source")
        let changedTarget = target.appendingPathComponent("changed-target")
        try fs.createDirectory(at: changedSource, withIntermediateDirectories: false)
        try fs.createDirectory(at: changedTarget, withIntermediateDirectories: false)
        let earlier = changedSource.appendingPathComponent("a")
        try Data([1, 2, 3]).write(to: earlier)
        try Data([4, 5, 6]).write(to: changedSource.appendingPathComponent("b"))
        #expect(throws: EZError.self) {
            try VerifiedCopy.run(sources: [changedSource], directory: changedTarget, expectedMount: mounted) { progress in
                guard progress.stage == .copying, progress.name == "b", progress.bytesDone == 0 else { return }
                do {
                    let handle = try FileHandle(forWritingTo: earlier)
                    defer { try? handle.close() }
                    try handle.write(contentsOf: Data([9]))
                } catch { Issue.record("Could not modify the earlier source: \(error)") }
            }
        }
        #expect(try fs.contentsOfDirectory(atPath: changedTarget.path).isEmpty)

        let growingSource = root.appendingPathComponent("growing-source")
        let growingTarget = target.appendingPathComponent("growing-target")
        try fs.createDirectory(at: growingSource, withIntermediateDirectories: false)
        try fs.createDirectory(at: growingTarget, withIntermediateDirectories: false)
        try Data([1, 2, 3]).write(to: growingSource.appendingPathComponent("first"))
        #expect(throws: EZError.self) {
            try VerifiedCopy.run(sources: [growingSource], directory: growingTarget, expectedMount: mounted) { progress in
                guard progress.stage == .copying, progress.bytesDone == 0 else { return }
                do { try Data([4]).write(to: growingSource.appendingPathComponent("added")) }
                catch { Issue.record("Could not add a source file: \(error)") }
            }
        }
        #expect(try fs.contentsOfDirectory(atPath: growingTarget.path).isEmpty)

        let verifySource = root.appendingPathComponent("verify-source")
        let verifyTarget = target.appendingPathComponent("verify-target")
        try fs.createDirectory(at: verifySource, withIntermediateDirectories: false)
        try fs.createDirectory(at: verifyTarget, withIntermediateDirectories: false)
        try Data([1, 2, 3]).write(to: verifySource.appendingPathComponent("a"))
        try Data([4, 5, 6]).write(to: verifySource.appendingPathComponent("b"))
        #expect(throws: EZError.self) {
            try VerifiedCopy.run(sources: [verifySource], directory: verifyTarget, expectedMount: mounted) { progress in
                guard progress.stage == .checking, progress.name == "b", progress.bytesDone == 0 else { return }
                do {
                    let stage = try #require(FileManager().contentsOfDirectory(atPath: verifyTarget.path).first)
                    let first = verifyTarget.appendingPathComponent(stage).appendingPathComponent("verify-source/a")
                    let handle = try FileHandle(forUpdating: first)
                    defer { try? handle.close() }
                    try handle.write(contentsOf: Data([9]))
                } catch { Issue.record("Could not change a verified file: \(error)") }
            }
        }
        #expect(try fs.contentsOfDirectory(atPath: verifyTarget.path).isEmpty)

        let existing = second.destination.appendingPathComponent("source/测试.txt")
        let open = try FileHandle(forReadingFrom: existing)
        #expect(throws: EZError.self) { try Tool.run("/sbin/umount", [target.path]) }
        try open.close()
        try unmountTestImage(image, at: target, backing: backing)
        try attach()
        #expect(try Data(contentsOf: existing) == data)
        #expect(try Data(contentsOf: second.destination.appendingPathComponent("source/._独立文件"))
            == Data("literal file".utf8))
        let xattr = try Tool.run("/usr/bin/xattr", ["-p", "com.ezntfs.fixture", existing.path])
        #expect(String(decoding: xattr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "metadata")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZNTFS_TEST_IMAGE"] != nil))
    func copiesAppleDoubleDirectoriesWithinAndBetweenNTFSVolumes() throws {
        let fixture = try #require(ProcessInfo.processInfo.environment["EZNTFS_TEST_IMAGE"])
        let driver = ProcessInfo.processInfo.environment["EZNTFS_TEST_DRIVER"]
        let fs = FileManager.default
        let base = URL(fileURLWithPath: try canonicalPath(fs.temporaryDirectory.path), isDirectory: true)
        let root = base.appendingPathComponent("ezntfs-metadata-" + UUID().uuidString, isDirectory: true)
        try fs.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let backing = try MountedDisk.at(root.path)
        let targets = ["first", "second"].map { root.appendingPathComponent($0, isDirectory: true) }
        let images = targets.map { $0.appendingPathExtension("img") }
        var createdMounts: [(target: URL, image: URL)] = []
        defer {
            do {
                for (target, image) in createdMounts {
                    try unmountTestImage(image, at: target, backing: backing)
                }
                try fs.removeItem(at: root)
            } catch { Issue.record("Temporary image cleanup failed at \(root.path): \(error.localizedDescription)") }
        }
        for (target, image) in zip(targets, images) {
            try fs.createDirectory(at: target, withIntermediateDirectories: false)
            createdMounts.append((target, image))
            _ = try Tool.run("/bin/cp", ["-c", fixture, image.path])
            try Mounting.mountImage(source: image.path, destination: target, label: "EZNTFS-QA", driver: driver)
        }
        let left = try MountedDisk.at(targets[0].path)
        let right = try MountedDisk.at(targets[1].path)
        #expect(left.device != right.device)

        let source = root.appendingPathComponent("资料", isDirectory: true)
        let empty = source.appendingPathComponent("项目/空目录", isDirectory: true)
        try fs.createDirectory(at: empty, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("项目/文件.txt")
        let contents = Data("独立验证".utf8)
        try contents.write(to: file)
        let attribute = "com.ezntfs.fixture"
        let values = [("项目", "folder-metadata"), ("项目/空目录", "empty-metadata"), ("项目/文件.txt", "file-metadata")]
        for (relative, value) in values {
            _ = try Tool.run("/usr/bin/xattr", ["-w", attribute, value, source.appendingPathComponent(relative).path])
        }

        let initial = try VerifiedCopy.run(sources: [source], directory: targets[0], expectedMount: left)
        let copiedSource = initial.destination.appendingPathComponent(source.lastPathComponent)
        #expect(fs.fileExists(atPath: copiedSource.appendingPathComponent("._项目").path))
        #expect(fs.fileExists(atPath: copiedSource.appendingPathComponent("项目/._空目录").path))

        for (target, mount) in zip(targets, [left, right]) {
            let result = try VerifiedCopy.run(sources: [copiedSource], directory: target, expectedMount: mount)
            #expect(result.files == 1)
            let destination = result.destination.appendingPathComponent(source.lastPathComponent)
            #expect(try Data(contentsOf: destination.appendingPathComponent("项目/文件.txt")) == contents)
            #expect(try fs.contentsOfDirectory(atPath: destination.appendingPathComponent("项目/空目录").path).isEmpty)
            for (relative, value) in values {
                let output = try Tool.run("/usr/bin/xattr", ["-p", attribute, destination.appendingPathComponent(relative).path])
                #expect(String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == value)
            }
        }
    }

}

func unmountTestImage(_ image: URL, at mount: URL, backing: MountedDisk) throws {
    // macOS workers can briefly hold files open even after the test closes its handles and windows.
    for attempt in 0...10 {
        let observed = try MountedDisk.at(mount.path)
        if observed == backing { return }
        guard observed.path == mount.path, observed.source == image.path, observed.kind == "macfuse" else {
            throw EZError("Unexpected mount identity during test image cleanup.")
        }
        do { _ = try Tool.run("/sbin/umount", [mount.path], queryTimeout: .seconds(2)) }
        catch {
            if try MountedDisk.at(mount.path) == backing { return }
            guard attempt < 10 else { throw error }
            Thread.sleep(forTimeInterval: 1)
            continue
        }
        guard try MountedDisk.at(mount.path) == backing else {
            throw EZError("Could not confirm the temporary image was unmounted.")
        }
        if attempt > 0 { print("Temporary image unmounted after retry (\(attempt)).") }
        return
    }
}
