import Darwin
@testable import EzNTFSCore
import Foundation
import Testing

struct DependencyTests {
    #if EZNTFS_MONTEREY_PREVIEW
    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZNTFS_TEST_IMAGE_TEMPLATE"] != nil))
    func reconnectsTheBundledTestDiskWithTheSameAutoMountIdentity() throws {
        let templatePath = try #require(ProcessInfo.processInfo.environment["EZNTFS_TEST_IMAGE_TEMPLATE"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ezNTFS 镜像 \(UUID().uuidString)")
        let fixture = PreviewTestImage(directory: directory)
        let template = URL(fileURLWithPath: templatePath)
        var connected: ExternalVolume?
        defer {
            if let connected {
                if (try? Disks.eject(connected)) != nil { try? FileManager.default.removeItem(at: directory) }
            } else {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let first = try fixture.connect(template: template)
        connected = first
        #expect(first.name == "EZNTFS-QA")
        #expect(first.mount?.kind == "ntfs")
        #expect(try fixture.connect(template: template).connection == first.connection)
        try Disks.eject(first)
        connected = nil

        let second = try fixture.connect(template: template)
        connected = second
        #expect(second.fingerprint == first.fingerprint)
        #expect(second.connection != first.connection)
        #expect(Disks.automaticCandidates([second], remembered: [first.fingerprint], attempted: []).map(\.id) == [second.id])
        try Disks.eject(second)
        connected = nil
    }

    #endif

    @Test func missingOrBrokenComponentsPreventReadWrite() {
        let ready = DependencyStatus.ready(path: "/fixture", version: "1")
        #expect(DependencyReport(macFUSE: ready, ntfs3g: ready, service: ready).canMountReadWrite)
        #expect(!DependencyReport(macFUSE: .missing, ntfs3g: ready, service: ready).canMountReadWrite)
        #expect(!DependencyReport(macFUSE: ready, ntfs3g: .unavailable("invalid hash"), service: ready).canMountReadWrite)
        #expect(!DependencyReport(macFUSE: ready, ntfs3g: ready, service: .missing).canMountReadWrite)
    }

    @Test func dependencyFlowSelectsTheSmallestApplicableInstaller() {
        let ready = DependencyStatus.ready(path: "/fixture", version: "5.5.0")
        let broken = DependencyStatus.unavailable("invalid hash")
        #expect(DependencyReport(macFUSE: .missing, ntfs3g: .missing, service: .missing).installStep() == .macFUSE)
        #expect(DependencyReport(macFUSE: broken, ntfs3g: ready, service: ready).installStep() == .macFUSE)
        #expect(DependencyReport(macFUSE: ready, ntfs3g: .missing, service: .missing).installStep() == .mainInstaller)
        #expect(DependencyReport(macFUSE: ready, ntfs3g: ready, service: broken).installStep() == .mainInstaller)
        #expect(DependencyReport(macFUSE: ready, ntfs3g: broken, service: ready).installStep() == .driverRepair)
        #expect(DependencyReport(macFUSE: ready, ntfs3g: ready, service: .disabled).installStep() == .serviceSettings)
        #expect(DependencyReport(macFUSE: ready, ntfs3g: ready, service: ready).installStep() == nil)
        #expect(DependencyReport(macFUSE: ready, ntfs3g: ready, service: ready)
            .installStep(needsMainInstall: true) == .mainInstaller)
    }

    @Test func disabledServiceRequiresAnExactLaunchdEntry() {
        #expect(Dependencies.isServiceDisabled("   \"local.ezntfs.mount\" => disabled"))
        #expect(Dependencies.isServiceDisabled("   \"local.ezntfs.mount\" => true,"))
        #expect(!Dependencies.isServiceDisabled("   \"local.ezntfs.mount\" => enabled"))
        #expect(!Dependencies.isServiceDisabled("   \"local.ezntfs.mount.other\" => disabled"))
    }

    @Test func macFUSERejectsATamperedImageBeforeAttaching() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixture) }
        try Data(repeating: 0, count: 22_946_514).write(to: fixture)
        #expect(throws: MacFUSEInstaller.PreparationError.verification) {
            try MacFUSEInstaller.extract(from: fixture)
        }
    }

    @Test func macFUSETriesMirrorsInOrderAndDiscardsAFileThatFailsVerification() async throws {
        let bad = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: bad) }
        try Data(repeating: 0, count: 22_946_514).write(to: bad)
        var attempts: [MacFUSEInstaller.Source] = []
        await #expect(throws: MacFUSEInstaller.PreparationError.verification) {
            try await MacFUSEInstaller.downloadImage(attempt: { source in
                attempts.append(source)
                if source == .tsinghua { return bad }
                throw URLError(.timedOut)
            })
        }
        #expect(attempts == [.official, .tsinghua, .nanjing])
        #expect(!FileManager.default.fileExists(atPath: bad.path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZNTFS_TEST_MACFUSE_MIRRORS"] == "1"))
    func macFUSEUsesARealVerifiedMirrorWhenEarlierSourcesFail() async throws {
        for mirror: MacFUSEInstaller.Source in [.tsinghua, .nanjing] {
            var attempts: [MacFUSEInstaller.Source] = []
            let image = try await MacFUSEInstaller.downloadImage(attempt: { source in
                attempts.append(source)
                guard source == mirror else { throw URLError(.timedOut) }
                return try await MacFUSEInstaller.download(source)
            })
            defer { try? FileManager.default.removeItem(at: image) }
            #expect(attempts == (mirror == .tsinghua ? [.official, .tsinghua] : [.official, .tsinghua, .nanjing]))
            let installer = try MacFUSEInstaller.extract(from: image)
            defer { try? FileManager.default.removeItem(at: installer.deletingLastPathComponent()) }
            #expect(installer.lastPathComponent == "Install macFUSE.pkg")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["EZNTFS_TEST_MACFUSE_DMG"] != nil))
    func macFUSEExtractsAndVerifiesTheOfficialPackageWithoutInstalling() throws {
        let image = try #require(ProcessInfo.processInfo.environment["EZNTFS_TEST_MACFUSE_DMG"])
        let installer = try MacFUSEInstaller.extract(from: URL(fileURLWithPath: image))
        defer { try? FileManager.default.removeItem(at: installer.deletingLastPathComponent()) }
        #expect(installer.lastPathComponent == "Install macFUSE.pkg")
        #expect(FileManager.default.fileExists(atPath: installer.path))
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
