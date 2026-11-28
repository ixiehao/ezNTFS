import AppKit
import Combine
import Darwin
import EzNTFSCore
import Foundation
import OSLog
import Security
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel(setup: LaunchMode.current.isSetup)
    static let automaticallyMountsNewDisks: Bool = {
        #if EZNTFS_MONTEREY
        true
        #else
        false
        #endif
    }()
    private let logger = Logger(subsystem: "local.ezntfs.app", category: "mount")
    private static let checkingMountMessage: InterfaceMessage = "health.checkingMount"
    private static let mountNotReadyMessage: InterfaceMessage = "health.mountNotReady"
    enum Activity: Equatable { case mounting, ejecting, choosingCopy, copying, testingImage }
    enum Preview: String {
        case ready, readOnly, copying, disconnected, dependencies, multiple, permissionDenied
    }
    enum LoginStatus { case notRegistered, enabled, requiresApproval }

    @Published private(set) var disks: [ExternalVolume] = []
    @Published private(set) var selection: UInt64?
    @Published private(set) var remembered: Set<DiskFingerprint> = []
    @Published private var automaticMountExclusions: Set<DiskFingerprint> = []
    private var recognizedVolumes: Set<DiskFingerprint> = []
    @Published private(set) var ejectedDevices: Set<UInt64> = []
    @Published private(set) var activityVolume: UInt64?
    @Published private(set) var activity: Activity? {
        didSet {
            guard activity != oldValue else { return }
            operationRevision &+= 1
            if activity == nil && refreshPending { scheduleRefresh() }
        }
    }
    @Published private(set) var progress: CopyProgress?
    @Published private(set) var cancellationRequested = false
    @Published private(set) var receipt: CopyReceipt?
    @Published private(set) var message: InterfaceMessage?
    @Published private(set) var language = AppLanguage.system
    @Published private(set) var isError = false
    @Published private(set) var diagnostic: String?
    @Published private(set) var needsDiskPermission = false
    @Published private(set) var needsExtensionApproval = false
    @Published private(set) var failedMountID: UInt64?
    @Published private(set) var autoMount = true
    @Published private(set) var loginStatus = LoginStatus.notRegistered

    @Published var dependencySheetPresented = false
    @Published private(set) var dependencyReport: DependencyReport?
    @Published private(set) var checkingDependencies = false
    @Published private(set) var dependencyNotice: InterfaceMessage?
    @Published private(set) var preparingDependency = false
    @Published private(set) var needsMainInstall = false
    let setup: Bool
    var setupArchitectureMatches: Bool {
        #if arch(x86_64)
        var translated: Int32 = 0
        var length = MemoryLayout<Int32>.size
        return sysctlbyname("sysctl.proc_translated", &translated, &length, nil, 0) != 0 || translated != 1
        #else
        return true
        #endif
    }
    private var awaitingDependency: DependencyInstallStep?
    private var downloadedFUSEInstaller: URL?
    private let resumeFUSEKey = "resumeAfterMacFUSE"

    private var operationRevision: UInt64 = 0
    private var refreshInProgress = false
    private var displayingScanError = false
    private var ejectNoticeDevice: UInt64?
    private var diskEvents: DiskEvents?
    private var nigateExitObserver: AnyCancellable?
    private var activationObserver: AnyCancellable?
    private var installerExitObserver: AnyCancellable?
    private var scheduledRefresh: Task<Void, Never>?
    private var refreshPending = false
    private var sleeping = false
    private var disksBeforeSleep: [ExternalVolume] = []
    private let bootSession: String?
    private var sessionAttempts: Set<UInt64> = []
    private var receiptVolume: UInt64?
    private var copyWorker: Task<CopyReceipt, Error>?
    private let defaults = UserDefaults.standard
    private let preview: Bool
    #if EZNTFS_MONTEREY_PREVIEW
    private let testImage = PreviewTestImage()
    private let testImageBatchKey = "montereyTestImageBatch"
    @Published private(set) var testImageFingerprint: DiskFingerprint?
    private var testImageBatch: String?

    var attachedTestImage: ExternalVolume? {
        disks.first { $0.fingerprint == testImageFingerprint }
    }

    func isManagedTestImage(_ volume: ExternalVolume) -> Bool {
        volume.fingerprint == testImageFingerprint
    }

    func connectTestImage() {
        guard !preview, !sleeping, activity == nil else { return }
        guard !preparingDependency, awaitingDependency == nil, dependencyReport?.canMountReadWrite == true else {
            openDependencyHealth()
            return
        }
        guard let template = Bundle.main.url(forResource: "EZNTFS-QA.img", withExtension: "gz") else {
            setMessage("testImage.missing", error: true)
            return
        }
        activity = .testingImage
        setMessage("testImage.connecting")
        Task {
            do {
                let image = testImage
                let volume = try await Task.detached(priority: .userInitiated) {
                    try image.connect(template: template)
                }.value
                if testImageFingerprint != volume.fingerprint {
                    testImageBatch = nil
                    defaults.removeObject(forKey: testImageBatchKey)
                }
                testImageFingerprint = volume.fingerprint
                selection = volume.id
                setMessage(nil)
            } catch {
                setMessage("testImage.connectFailed", error: true, diagnostic: error.localizedDescription)
            }
            activity = nil
            await refresh()
        }
    }

    func verifyTestImage(_ volume: ExternalVolume) {
        guard !preview, activity == nil, isManagedTestImage(volume), volume.isWritable else { return }
        let previous = testImageBatch
        activity = .testingImage
        setMessage("testImage.verifying")
        Task {
            do {
                let image = testImage
                let result = try await Task.detached(priority: .userInitiated) {
                    if let previous {
                        try image.verifySample(in: previous, on: volume)
                        return previous
                    }
                    return try image.writeSample(to: volume)
                }.value
                testImageBatch = result
                defaults.set([volume.fingerprint.serial: result], forKey: testImageBatchKey)
                setMessage(previous == nil ? "testImage.writePassed" : "testImage.readPassed")
            } catch {
                setMessage("testImage.verifyFailed", error: true, diagnostic: error.localizedDescription)
                testImageBatch = nil
                defaults.removeObject(forKey: testImageBatchKey)
            }
            activity = nil
            await refresh()
        }
    }
    #endif

    private struct StoredEjections: Codable {
        let bootSession: String
        let connections: Set<UInt64>
    }

    private struct LegacyEjection: Decodable {
        let bootSession: String
        let usbConnection: UInt64
    }

    init(preview: Preview? = nil, setup: Bool = false) {
        self.preview = preview != nil
        self.setup = setup
        bootSession = preview == nil && !setup ? Self.currentBootSession() : nil
        language = defaults.string(forKey: "interfaceLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .system
        if let preview {
            configurePreview(preview)
            return
        }
        guard !setup else { return }
        remembered = RememberedDisks.load(defaults)
        if Self.automaticallyMountsNewDisks {
            automaticMountExclusions = RememberedDisks.loadExclusions(defaults)
            recognizedVolumes = RememberedDisks.loadRecognizedVolumes(defaults)
        }
        autoMount = defaults.object(forKey: "autoMount") as? Bool ?? true
        #if EZNTFS_MONTEREY_PREVIEW
        testImageFingerprint = testImage.fingerprint
        if let testImageFingerprint {
            testImageBatch = defaults.dictionary(forKey: testImageBatchKey)?[testImageFingerprint.serial] as? String
        }
        #endif
        restoreEjections()
    }

    private func configurePreview(_ preview: Preview) {
        let identity = DiskFingerprint(serial: "PREVIEW", vendor: 0x0480, product: 0,
                                       partitionOffset: 1_048_576, partitionBytes: 2_000_396_836_864)
        remembered = [identity]
        if preview == .dependencies {
            dependencyReport = DependencyReport(macFUSE: .ready(path: "/example/macFUSE", version: "5.5.0"),
                                                ntfs3g: .unavailable("Preview: driver verification failed."),
                                                service: .missing)
            dependencySheetPresented = true
            return
        }
        guard preview != .disconnected else { return }

        let path = "/Volumes/ezNTFS Preview"
        let readOnly = preview == .readOnly || preview == .permissionDenied
        let mount = VolumeMount(path: path, kind: readOnly ? "ntfs" : "macfuse",
                                readOnly: readOnly, availableCapacity: 497_320_000_000)
        disks = [ExternalVolume(connection: 1, deviceConnection: 2, fingerprint: identity, partition: "disk4s1",
                                wholeDisk: "disk4", name: "TOSHIBA EXT",
                                mount: mount, fileSystemConfirmed: true)]
        selection = 1
        if preview == .multiple || preview == .permissionDenied {
            let second = DiskFingerprint(serial: "PREVIEW-2", vendor: 1, product: 2,
                                         partitionOffset: 1_048_576, partitionBytes: 512_000_000_000)
            let writable = VolumeMount(path: "/Volumes/Preview 2", kind: "macfuse", readOnly: false,
                                       availableCapacity: 248_000_000_000)
            disks.append(ExternalVolume(connection: 3, deviceConnection: 4, fingerprint: second, partition: "disk5s2",
                                        wholeDisk: "disk5", name: "Work Backup",
                                        mount: preview == .permissionDenied ? writable : nil, fileSystemConfirmed: true))
            let third = DiskFingerprint(serial: "PREVIEW-3", vendor: 1, product: 3,
                                        partitionOffset: 1_048_576, partitionBytes: 4_000_000_000_000)
            let native = VolumeMount(path: "/Volumes/Preview 3",
                                     kind: preview == .permissionDenied ? "macfuse" : "ntfs",
                                     readOnly: preview != .permissionDenied, availableCapacity: 2_210_000_000_000)
            disks.append(ExternalVolume(connection: 5, deviceConnection: 6, fingerprint: third, partition: "disk6s2",
                                        wholeDisk: "disk6", name: "Seagate Backup Plus Drive", mount: native, fileSystemConfirmed: true))
        }
        if preview == .ready {
            receiptVolume = 1
            receipt = CopyReceipt(destination: URL(fileURLWithPath: path + "/Example Copy"),
                                  files: 256, bytes: 4_214_656, writeSeconds: 18, verificationSeconds: 0.07)
        }
        if preview == .permissionDenied {
            showMountFailure("Error opening '/dev/disk4s1': Operation not permitted")
            failedMountID = selection
        }
        if preview == .copying {
            activity = .copying
            progress = CopyProgress(name: "Archive / Photo_0132.jpg", stage: .checking, filesCompleted: 131,
                                    fileCount: 256, bytesDone: 20, fileBytes: 35)
        }
    }

    var selected: ExternalVolume? { disks.first { $0.id == selection } }
    var waitingToDisconnect: Bool { disks.isEmpty && !ejectedDevices.isEmpty }

    var visibleReceipt: CopyReceipt? {
        guard let selected, selected.connection == receiptVolume, let receipt, let mount = selected.mount,
              receipt.destination.path.hasPrefix(mount.path + "/") else { return nil }
        return receipt
    }

    func diskLabel(_ disk: ExternalVolume) -> String {
        disks.lazy.filter { $0.name == disk.name }.dropFirst().isEmpty
            ? disk.name : "\(disk.name) · \(disk.partition)"
    }

    func select(_ id: UInt64) {
        guard activity == nil, disks.contains(where: { $0.id == id }), selection != id else { return }
        selection = id
        if !needsDiskPermission { setMessage(nil) }
    }

    func startMonitoring() {
        guard !preview, diskEvents == nil else { return }
        if nigateExitObserver == nil {
            nigateExitObserver = NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.didTerminateApplicationNotification)
                .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
                .filter { $0.bundleIdentifier == "io.hoochanlon.github" }
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleRefresh() }
                }
        }
        observeDependencyReturn()
        diskEvents = DiskEvents(onChange: { [weak self] in self?.scheduleRefresh() },
                                onSleep: { [weak self] in self?.prepareForSleep() },
                                onWake: { [weak self] in self?.refreshAfterWake() })
        if diskEvents == nil {
            logger.error("Could not subscribe to macOS disk events.")
            setMessage("error.diskEvents", error: true)
        }
        scheduleRefresh()
        Task { await checkDependencies() }
    }

    private func scheduleRefresh() {
        guard scheduledRefresh == nil else { return }
        scheduledRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self else { return }
            scheduledRefresh = nil
            await refresh()
        }
    }

    private func prepareForSleep() {
        guard !sleeping else { return }
        sleeping = true
        disksBeforeSleep = disks
        operationRevision &+= 1
    }

    private func refreshAfterWake() {
        sessionAttempts = Disks.mountAttemptsAfterWake(sessionAttempts, disksBeforeSleep: disksBeforeSleep)
        disksBeforeSleep.removeAll()
        sleeping = false
        scheduleRefresh()
    }

    func refresh() async {
        guard !preview else { return }
        guard !sleeping, !refreshInProgress, activity == nil else {
            refreshPending = true
            return
        }
        refreshPending = false
        let currentLoginStatus = Self.readLoginStatus()
        if loginStatus != currentLoginStatus { loginStatus = currentLoginStatus }

        let connectedEjections = ejectedDevices.filter { Disks.isDeviceConnected($0) }
        if connectedEjections != ejectedDevices {
            saveEjections(connectedEjections)
            if let ejectNoticeDevice, !connectedEjections.contains(ejectNoticeDevice) { setMessage(nil) }
        }

        refreshInProgress = true
        defer {
            refreshInProgress = false
            if refreshPending && activity == nil && !sleeping { scheduleRefresh() }
        }
        let excluded = ejectedDevices
        let prior = remembered.union(recognizedVolumes).union(disks.map(\.fingerprint))
        #if EZNTFS_MONTEREY_PREVIEW
        let known = prior.union([testImageFingerprint].compactMap { $0 })
        #else
        let known = prior
        #endif
        let revision = operationRevision
        let result = await Task.detached(priority: .utility) {
            Result { try Disks.scan(known: known, excluding: excluded) }
        }.value
        guard !sleeping, activity == nil, operationRevision == revision, ejectedDevices == excluded else {
            refreshPending = true
            return
        }

        switch result {
        case let .success(inventory):
            if disks != inventory { disks = inventory }
            if selected == nil { selection = disks.first?.id }
            if displayingScanError { setMessage(nil) }
            if autoMount, let target = Disks.automaticCandidates(disks, policy: automaticMountPolicy,
                                                                attempted: sessionAttempts).first {
                startMount(target)
            }
        case let .failure(error):
            disks = []
            selection = nil
            if !displayingScanError || diagnostic != error.localizedDescription {
                logger.error("Disk status refresh failed: \(error.localizedDescription, privacy: .public)")
            }
            setMessage("error.refresh", error: true, diagnostic: error.localizedDescription)
            displayingScanError = true
        }
    }

    private func restoreEjections() {
        guard let bootSession else { return }
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: "ejectedDevices"),
           let saved = try? decoder.decode(StoredEjections.self, from: data), saved.bootSession == bootSession {
            ejectedDevices = saved.connections.filter { Disks.isDeviceConnected($0) }
        } else if defaults.data(forKey: "ejectedDevices") == nil,
                  let data = defaults.data(forKey: "ejectedUSB"),
                  let saved = try? decoder.decode(LegacyEjection.self, from: data),
                  saved.bootSession == bootSession, Disks.isDeviceConnected(saved.usbConnection) {
            saveEjections([saved.usbConnection])
        }
    }

    private func saveEjections(_ connections: Set<UInt64>) {
        ejectedDevices = connections
        if let bootSession,
           let data = try? JSONEncoder().encode(StoredEjections(bootSession: bootSession, connections: connections)) {
            defaults.set(data, forKey: "ejectedDevices")
        }
    }

    private static func currentBootSession() -> String? {
        var bytes = [CChar](repeating: 0, count: 64)
        var count = bytes.count
        let result = bytes.withUnsafeMutableBufferPointer {
            sysctlbyname("kern.bootsessionuuid", $0.baseAddress, &count, nil, 0)
        }
        guard result == 0 else { return nil }
        return UUID(uuidString: String(decoding: bytes.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self))?
            .uuidString
    }

    func automaticMountRestriction(for disk: ExternalVolume) -> String? {
        if !Self.automaticallyMountsNewDisks && !disk.fingerprint.canRemember { return language.text("error.noIdentity") }
        if disks.contains(where: { $0.id != disk.id && $0.fingerprint == disk.fingerprint }) {
            return language.text("error.duplicateIdentity")
        }
        if !autoMount { return language.text("error.autoMountOff") }
        return nil
    }

    private var automaticMountPolicy: AutomaticMountPolicy {
        Self.automaticallyMountsNewDisks ? .connectedExcept(automaticMountExclusions) : .remembered(remembered)
    }

    func automaticMountEnabled(for disk: ExternalVolume) -> Bool {
        automaticMountPolicy.includes(disk.fingerprint)
    }

    func setDiskAutomaticMount(_ enabled: Bool, diskID: UInt64) {
        guard !preview, activity == nil, let disk = disks.first(where: { $0.id == diskID }),
              automaticMountRestriction(for: disk) == nil else { return }
        do {
            if Self.automaticallyMountsNewDisks {
                var exclusions = automaticMountExclusions
                if enabled { exclusions.remove(disk.fingerprint) }
                else { exclusions.insert(disk.fingerprint) }
                try RememberedDisks.saveExclusions(exclusions, to: defaults)
                automaticMountExclusions = exclusions
            } else {
                var updated = remembered
                if enabled { updated.insert(disk.fingerprint) }
                else { updated.remove(disk.fingerprint) }
                try RememberedDisks.save(updated, to: defaults)
                remembered = updated
            }
            setMessage(InterfaceMessage(enabled ? "notice.autoMountOn" : "notice.autoMountOff",
                               arguments: [disk.name]))
            if enabled {
                sessionAttempts.remove(disk.connection)
                scheduleRefresh()
            }
        } catch {
            setMessage("error.saveAutoMount", error: true, diagnostic: error.localizedDescription)
        }
    }

    func setLanguage(_ language: AppLanguage) {
        self.language = language
        if !preview { defaults.set(language.rawValue, forKey: "interfaceLanguage") }
    }

    func setAutomatic(_ enabled: Bool) {
        guard !preview else { return }
        autoMount = enabled
        defaults.set(enabled, forKey: "autoMount")
        if enabled {
            sessionAttempts = []
            scheduleRefresh()
        }
    }

    func setLogin(_ enabled: Bool) {
        guard !preview, #available(macOS 13.0, *) else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginStatus = Self.readLoginStatus()
            if loginStatus == .requiresApproval {
                setMessage("settings.loginHint")
            }
        } catch {
            setMessage("error.login", error: true, diagnostic: error.localizedDescription)
        }
    }

    private static func readLoginStatus() -> LoginStatus {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return .enabled
            case .requiresApproval: return .requiresApproval
            default: break
            }
        }
        return .notRegistered
    }

    func openLegacyLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.users") {
            NSWorkspace.shared.open(url)
        }
    }

    func openDependencyHealth() {
        dependencySheetPresented = true
        Task { await checkDependencies() }
    }

    var dependencyStep: DependencyInstallStep? {
        let step = dependencyReport?.installStep(needsMainInstall: needsMainInstall)
        #if EZNTFS_MONTEREY || EZNTFS_MONTEREY_PREVIEW
        if #unavailable(macOS 13.0), step == .serviceSettings { return .mainInstaller }
        #endif
        return step
    }

    func startSetup() {
        guard setupArchitectureMatches else {
            dependencyNotice = "setup.wrongArchitecture"
            return
        }
        observeDependencyReturn()
        if defaults.bool(forKey: resumeFUSEKey) { awaitingDependency = .macFUSE }
        Task { await checkDependencies() }
    }

    private func observeDependencyReturn() {
        activationObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.setup || self.dependencySheetPresented || self.awaitingDependency != nil
                            || self.dependencyReport?.canMountReadWrite != true else { return }
                    await self.checkDependencies()
                }
            }
        installerExitObserver = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.bundleIdentifier == "com.apple.installer" }
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.removeDownloadedInstaller()
                    guard self.awaitingDependency != nil else { return }
                    await self.checkDependencies()
                }
            }
    }

    func checkDependencies(startInstall: Bool = false) async {
        guard !preview, !checkingDependencies, !preparingDependency, !setup || setupArchitectureMatches,
              !startInstall || activity == nil else { return }
        checkingDependencies = true
        if startInstall { dependencyNotice = nil }
        let fromSetup = setup
        let targetBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let (report, requiresMain) = await Task.detached(priority: .utility) {
            let report = Dependencies.inspect(fromSetup: fromSetup)
            let requiresMain = fromSetup && Dependencies.needsInstallation(build: targetBuild)
            return (report, requiresMain)
        }.value
        dependencyReport = report
        needsMainInstall = requiresMain
        checkingDependencies = false
        if startInstall || dependencyStep == nil || completedDependencyStep(report) {
            if setup { defaults.removeObject(forKey: resumeFUSEKey) }
            let continuing = startInstall || awaitingDependency != nil
            awaitingDependency = nil
            if let step = dependencyStep, continuing {
                await openDependencyInstaller(for: step)
            } else if dependencyStep == nil {
                dependencyNotice = nil
            }
        }
        guard !setup else { return }
        if message == Self.checkingMountMessage || message == Self.mountNotReadyMessage {
            let ready = dependencyReport?.canMountReadWrite == true
            setMessage(ready ? nil : Self.mountNotReadyMessage, error: !ready)
        }
        await refresh()
    }

    func installDependency() {
        Task { await checkDependencies(startInstall: true) }
    }

    private func completedDependencyStep(_ report: DependencyReport) -> Bool {
        switch awaitingDependency {
        case .macFUSE: report.macFUSE.path != nil
        case .mainInstaller: !needsMainInstall && report.ntfs3g.path != nil && report.service == .disabled
        case .driverRepair: report.ntfs3g.path != nil
        case .serviceSettings: report.service.path != nil
        case nil: false
        }
    }

    private func openDependencyInstaller(for step: DependencyInstallStep) async {
        guard activity == nil else {
            dependencyNotice = "health.repairBusy"
            return
        }
        if step == .serviceSettings, #available(macOS 13.0, *) {
            awaitingDependency = step
            dependencyNotice = "health.awaitingService"
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        preparingDependency = true
        defer { preparingDependency = false }
        guard await disksAllowInstallation() else { return }

        do {
            let installer: URL
            switch step {
            case .macFUSE:
                if downloadedFUSEInstaller == nil {
                    let report: @Sendable (MacFUSEInstaller.Source) async -> Void = { [weak self] source in
                        await self?.showFUSEDownload(source)
                    }
                    downloadedFUSEInstaller = try await Task.detached(priority: .userInitiated) {
                        try await MacFUSEInstaller.prepare(reporting: report)
                    }.value
                }
                guard let downloadedFUSEInstaller else { return }
                installer = downloadedFUSEInstaller
                guard await disksAllowInstallation() else {
                    removeDownloadedInstaller()
                    return
                }
            case .mainInstaller:
                if setup {
                    installer = try bundledInstaller("ezNTFS-Install")
                    guard await closeInstalledAppForUpgrade(), await disksAllowInstallation() else { return }
                } else {
                    guard FileManager.default.fileExists(atPath: Dependencies.cachedInstaller.path) else {
                        dependencyNotice = "health.mainInstallerMissing"
                        return
                    }
                    try SystemDriver.protectedPath(Dependencies.cachedInstaller)
                    installer = Dependencies.cachedInstaller
                }
            case .driverRepair:
                installer = try bundledInstaller("ezNTFS-Driver")
            case .serviceSettings:
                return
            }
            guard NSWorkspace.shared.open(installer) else {
                if step == .macFUSE { removeDownloadedInstaller() }
                dependencyNotice = "health.installerError"
                return
            }
            awaitingDependency = step
            if setup && step == .macFUSE { defaults.set(true, forKey: resumeFUSEKey) }
            dependencyNotice = step == .macFUSE ? "health.awaitingFuse" : "health.awaitingInstaller"
        } catch MacFUSEInstaller.PreparationError.download {
            dependencyNotice = "health.downloadError"
        } catch {
            dependencyNotice = step == .macFUSE ? "health.verifyError" : "health.installerError"
            logger.error("Dependency installer preparation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func disksAllowInstallation() async -> Bool {
        let usage = await Task.detached(priority: .utility) { Dependencies.installationUsage() }.value
        dependencyNotice = activity == nil ? usage.repairBlockMessage : "health.repairBusy"
        return dependencyNotice == nil
    }

    private func bundledInstaller(_ name: String) throws -> URL {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              let url = Bundle.main.url(forResource: name, withExtension: "pkg") else {
            throw EZError("Installer bundle verification failed.")
        }
        return url
    }

    private func removeDownloadedInstaller() {
        guard let downloadedFUSEInstaller else { return }
        try? FileManager.default.removeItem(at: downloadedFUSEInstaller.deletingLastPathComponent())
        self.downloadedFUSEInstaller = nil
    }

    private func showFUSEDownload(_ source: MacFUSEInstaller.Source) {
        dependencyNotice = switch source {
        case .official: "health.downloadingFuse"
        case .tsinghua: "health.downloadingFuseTsinghua"
        case .nanjing: "health.downloadingFuseNanjing"
        }
    }

    var hasInstalledApp: Bool {
        setup && Bundle(url: Dependencies.installedApp) != nil
    }

    func openInstalledApp(closeSetup: Bool = true) {
        if NSWorkspace.shared.open(Dependencies.installedApp), closeSetup { NSApp.terminate(nil) }
    }

    private func closeInstalledAppForUpgrade() async -> Bool {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "local.ezntfs.app").filter {
            $0.bundleURL?.standardizedFileURL.path == Dependencies.installedApp.standardizedFileURL.path && !$0.isTerminated
        }
        guard !running.isEmpty else { return true }
        running.forEach { _ = $0.terminate() }
        let deadline = DispatchTime.now() + .seconds(4)
        while DispatchTime.now() < deadline {
            if running.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        dependencyNotice = "health.quitToInstall"
        return false
    }

    func startMount() {
        guard let selected else { return }
        startMount(selected, userInitiated: true)
    }

    func startMount(diskID: UInt64) {
        guard activity == nil, let target = disks.first(where: { $0.id == diskID }) else { return }
        select(diskID)
        startMount(target, userInitiated: true)
    }

    private func startMount(_ target: ExternalVolume, userInitiated: Bool = false) {
        guard !preview, activity == nil, !preparingDependency, awaitingDependency == nil, target.canMountReadWrite else { return }
        guard let report = dependencyReport else {
            if userInitiated { setMessage(Self.checkingMountMessage) }
            return
        }
        guard report.canMountReadWrite else {
            setMessage(Self.mountNotReadyMessage, error: true)
            return
        }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "io.hoochanlon.github").isEmpty {
            setMessage("error.nigate", error: true)
            return
        }
        sessionAttempts.insert(target.connection)
        activityVolume = target.id
        activity = .mounting
        setMessage(InterfaceMessage("notice.mounting", arguments: [target.name]))
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try await MountRetry.run(partition: target.partition) {
                        try MountServiceClient.mount(target)
                    }
                }.value
                if Self.automaticallyMountsNewDisks, target.fingerprint.canRemember,
                   recognizedVolumes.insert(target.fingerprint).inserted {
                    try? RememberedDisks.saveRecognizedVolumes(recognizedVolumes, to: defaults)
                }
                logger.notice("Read-write mount confirmed.")
                setMessage(InterfaceMessage("notice.mounted", arguments: [target.name]))
            } catch {
                logger.error("Read-write mount failed: \(error.localizedDescription, privacy: .public)")
                showMountFailure(error.localizedDescription)
                failedMountID = target.id
            }
            activityVolume = nil
            activity = nil
            await refresh()
        }
    }

    func eject() {
        guard let selected else { return }
        eject(diskID: selected.id)
    }

    func eject(diskID: UInt64) {
        guard !preview, activity == nil, let target = disks.first(where: { $0.id == diskID }) else { return }
        select(diskID)
        // If eject leaves another partition on this disk unmounted, keep it eligible for a manual retry.
        sessionAttempts.formUnion(disks.lazy.filter { $0.deviceConnection == target.deviceConnection }.map(\.connection))
        activityVolume = target.id
        activity = .ejecting
        setMessage(InterfaceMessage("notice.ejecting", arguments: [target.name]))
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try Disks.eject(target) }.value
                saveEjections(ejectedDevices.union([target.deviceConnection]))
                if let receiptVolume, disks.contains(where: {
                    $0.id == receiptVolume && $0.deviceConnection == target.deviceConnection
                }) {
                    self.receiptVolume = nil
                    receipt = nil
                }
                disks.removeAll { $0.deviceConnection == target.deviceConnection }
                selection = disks.first?.id
                setMessage(InterfaceMessage("notice.ejected", arguments: [target.name]))
                ejectNoticeDevice = target.deviceConnection
            } catch {
                setMessage(InterfaceMessage("error.eject", arguments: [target.name]),
                           error: true, diagnostic: error.localizedDescription)
            }
            activityVolume = nil
            activity = nil
            await refresh()
        }
    }

    func openDiskPermission() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    func copyMountHelperPath() {
        let path = SystemDriver.serviceBundle.path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func revealMountService() {
        NSWorkspace.shared.activateFileViewerSelecting([SystemDriver.serviceBundle])
    }

    func openExtensionApproval() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?General") {
            NSWorkspace.shared.open(url)
        }
    }

    func retryFailedMount() {
        if let failedMountID { startMount(diskID: failedMountID) }
    }

    private func showMountFailure(_ detail: String) {
        let lower = detail.lowercased()
        if lower.contains("system extension blocked") || lower.contains("the system extension required for mounting macfuse")
            || lower.contains("the macfuse kernel extension is not loaded") || lower.contains("allow loading system software") {
            setMessage("error.extensionApproval", error: true, diagnostic: detail, needsExtensionApproval: true)
        } else if lower.contains("operation not permitted") || lower.contains("permission denied") {
            setMessage("error.permission",
                       error: true, diagnostic: detail, needsDiskPermission: true)
        } else if lower.contains("hibernated") {
            setMessage("error.hibernated",
                       error: true, diagnostic: detail)
        } else if lower.contains("resource busy") || lower.contains("dissented") {
            setMessage("error.busy", error: true, diagnostic: detail)
        } else {
            setMessage("error.mount",
                       error: true, diagnostic: detail)
        }
    }

    func chooseCopy() {
        guard !preview else { return }
        guard activity == nil, let selected, let mount = selected.mount, selected.isWritable else { return }
        activity = .choosingCopy
        Task {
            defer { if activity == .choosingCopy { activity = nil } }
            let picker = NSOpenPanel()
            picker.title = language.text("copy.chooseSource")
            picker.prompt = language.text("button.choose")
            picker.canChooseFiles = true
            picker.canChooseDirectories = true
            picker.allowsMultipleSelection = true
            guard await picker.begin() == .OK, !picker.urls.isEmpty else { return }
            let sources = picker.urls

            let destination = NSOpenPanel()
            destination.title = language.text("copy.chooseDestination", selected.name)
            destination.prompt = language.text("copy.start")
            destination.directoryURL = URL(fileURLWithPath: mount.path, isDirectory: true)
            destination.canChooseFiles = false
            destination.canChooseDirectories = true
            destination.canCreateDirectories = false
            guard await destination.begin() == .OK, let directory = destination.url else { return }
            copy(sources, to: directory, on: selected)
        }
    }

    func showVolume() {
        guard !preview else { return }
        guard let path = selected?.mount?.path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    func revealReceipt() {
        guard !preview, let receipt = visibleReceipt else { return }
        NSWorkspace.shared.activateFileViewerSelecting([receipt.destination])
    }

    func cancelCopy() {
        guard !preview, activity == .copying, !cancellationRequested else { return }
        cancellationRequested = true
        copyWorker?.cancel()
        setMessage("copy.waiting")
    }

    private func copy(_ sources: [URL], to directory: URL, on volume: ExternalVolume) {
        activity = .copying
        progress = nil
        receipt = nil
        receiptVolume = nil
        setMessage("copy.scanning")
        let (updates, updatesSink) = AsyncStream.makeStream(of: CopyProgress.self, bufferingPolicy: .bufferingNewest(1))
        let worker = Task.detached(priority: .userInitiated) {
            defer { updatesSink.finish() }
            let mount = try Disks.copyMount(for: volume)
            return try VerifiedCopy.run(sources: sources, directory: directory, expectedMount: mount) {
                updatesSink.yield($0)
            }
        }
        copyWorker = worker
        Task {
            for await update in updates { progress = update }
            do {
                let result = try await worker.value
                receiptVolume = volume.id
                receipt = result
                setMessage(nil)
            } catch is CancellationError {
                setMessage("copy.cancelled")
            } catch {
                setMessage("copy.failed", error: true, diagnostic: error.localizedDescription)
            }
            copyWorker = nil
            cancellationRequested = false
            progress = nil
            activity = nil
            await refresh()
        }
    }

    private func setMessage(_ text: InterfaceMessage?, error: Bool = false, diagnostic: String? = nil,
                            needsDiskPermission: Bool = false, needsExtensionApproval: Bool = false) {
        displayingScanError = false
        ejectNoticeDevice = nil
        if message != text { message = text }
        if isError != error { isError = error }
        if self.diagnostic != diagnostic { self.diagnostic = diagnostic }
        if self.needsDiskPermission != needsDiskPermission { self.needsDiskPermission = needsDiskPermission }
        if self.needsExtensionApproval != needsExtensionApproval { self.needsExtensionApproval = needsExtensionApproval }
        if failedMountID != nil { failedMountID = nil }
    }
}
