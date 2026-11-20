import Darwin
@testable import EzNTFSCore
import Foundation
import Testing

struct DependencyTests {
    @Test func missingOrBrokenComponentsPreventReadWrite() {
        let ready = DependencyStatus.ready(path: "/fixture", version: "1")
        #expect(DependencyReport(macFUSE: ready, ntfs3g: ready, service: ready).canMountReadWrite)
        #expect(!DependencyReport(macFUSE: .missing, ntfs3g: ready, service: ready).canMountReadWrite)
        #expect(!DependencyReport(macFUSE: ready, ntfs3g: .unavailable("invalid hash"), service: ready).canMountReadWrite)
        #expect(!DependencyReport(macFUSE: ready, ntfs3g: ready, service: .missing).canMountReadWrite)
    }

    @Test func repairOnlyBlocksDriverExecutablesFromTheEZNTFSInstallation() {
        let root = "/Library/Application Support/ezNTFS/Driver"
        let driver = root + "/2026.9.28-test/bin/ntfs-3g"
        #expect(DriverUsage.belongs(driver, to: root))
        #expect(DriverUsage.belongs("/System/Volumes/Data" + driver, to: root))
        #expect(!DriverUsage.belongs("/opt/homebrew/bin/ntfs-3g", to: root))
        #expect(!DriverUsage.belongs(root + "-other/bin/ntfs-3g", to: root))
    }

    @Test func systemDriverPolicyRejectsUserWritableAndSymbolicPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ezntfs-dependencies-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent("ntfs-3g")
        try Data().write(to: candidate)
        #expect(chmod(candidate.path, 0o777) == 0)
        #expect(throws: EZError.self) { try SystemDriver.protectedPath(candidate) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: candidate)
        #expect(throws: EZError.self) { try SystemDriver.protectedPath(link) }
    }
}
