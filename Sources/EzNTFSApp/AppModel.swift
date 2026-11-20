import AppKit
import Combine
import Darwin
import EzNTFSCore
import Foundation
import OSLog
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    private let logger = Logger(subsystem: "local.ezntfs.app", category: "mount")
    private static let checkingMountMessage: InterfaceMessage = "health.checkingMount"
    private static let mountNotReadyMessage: InterfaceMessage = "health.mountNotReady"
    enum Activity: Equatable { case mounting, ejecting, choosingCopy, copying }
    enum Preview: String { case ready, readOnly, copying, disconnected, dependencies, multiple, permissionDenied }

    @Published private(set) var disks: [ExternalVolume] = []
    @Published private(set) var selection: UInt64?
    @Published private(set) var remembered: Set<DiskFingerprint> = []
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
    @Published private(set) var autoMount = true
    @Published private(set) var loginStatus = SMAppService.Status.notRegistered

    @Published var dependencySheetPresented = false
    @Published private(set) var dependencyReport: DependencyReport?
    @Published private(set) var checkingDependencies = false
    @Published private(set) var dependencyInstallError: InterfaceMessage?

    private var operationRevision: UInt64 = 0
    private var refreshInProgress = false
    private var displayingScanError = false
    private var ejectNoticeDevice: UInt64?
    private var diskEvents: DiskEvents?
    private var nigateExitObserver: AnyCancellable?
    private var activationObserver: AnyCancellable?
    private var scheduledRefresh: Task<Void, Never>?
    private var refreshPending = false
    private let bootSession: String?
    private var sessionAttempts: Set<UInt64> = []
    private var receiptVolume: UInt64?
    private var copyWorker: Task<CopyReceipt, Error>?
    private let defaults = UserDefaults.standard
    private let preview: Bool

    private struct StoredEjections: Codable {
        let bootSession: String
        let connections: Set<UInt64>
    }

    private struct LegacyEjection: Decodable {
        let bootSession: String
        let usbConnection: UInt64
    }

    init(preview: Preview? = nil) {
        self.preview = preview != nil
        bootSession = preview == nil ? Self.currentBootSession() : nil
        language = defaults.string(forKey: "interfaceLanguage").flatMap(AppLanguage.init(rawValue:)) ?? .system
        if let preview {
            configurePreview(preview)
            return
        }
        remembered = RememberedDisks.load(defaults)
        autoMount = defaults.object(forKey: "autoMount") as? Bool ?? true
        restoreEjections()
    }

    private func configurePreview(_ preview: Preview) {
        let identity = DiskFingerprint(serial: "PREVIEW", vendor: 0x0480, product: 0,
                                       partitionOffset: 1_048_576, partitionBytes: 2_000_396_836_864)
        remembered = [identity]
        if preview == .dependencies {
            dependencyReport = DependencyReport(macFUSE: .ready(path: "/example/macFUSE", version: "5.5.0"),
                                                ntfs3g: .unavailable("Preview: driver verification failed."),
                                                service: .missing,
                                                driverUsage: .inUse)
            dependencySheetPresented = true
            return
        }
        guard preview != .disconnected else { return }

        let path = "/Volumes/ezNTFS Preview"
        let readOnly = preview == .readOnly || preview == .permissionDenied
        let mount = VolumeMount(path: path, kind: readOnly ? "ntfs" : "macfuse",
                                readOnly: readOnly, availableCapacity: 497_320_000_000)
        disks = [ExternalVolume(connection: 1, deviceConnection: 2, fingerprint: identity, partition: "disk4s1",
                                wholeDisk: "disk4", name: "TOSHIBA EXT", mount: mount, fileSystemConfirmed: true)]
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
        activationObserver = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.dependencySheetPresented || self.dependencyReport?.canMountReadWrite != true else { return }
                    await self.checkDependencies()
                }
            }
        diskEvents = DiskEvents { [weak self] in self?.scheduleRefresh() }
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
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            scheduledRefresh = nil
            await refresh()
        }
    }

    func refresh() async {
        guard !preview else { return }
        guard !refreshInProgress, activity == nil else {
            refreshPending = true
            return
        }
        refreshPending = false
        let currentLoginStatus = SMAppService.mainApp.status
        if loginStatus != currentLoginStatus { loginStatus = currentLoginStatus }

        let connectedEjections = ejectedDevices.filter { Disks.isDeviceConnected($0) }
        if connectedEjections != ejectedDevices {
            saveEjections(connectedEjections)
            if let ejectNoticeDevice, !connectedEjections.contains(ejectNoticeDevice) { setMessage(nil) }
        }

        refreshInProgress = true
        defer {
            refreshInProgress = false
            if refreshPending && activity == nil { scheduleRefresh() }
        }
        let excluded = ejectedDevices
        let known = remembered.union(disks.map(\.fingerprint))
        let revision = operationRevision
        let result = await Task.detached(priority: .utility) {
            Result { try Disks.scan(known: known, excluding: excluded) }
        }.value
        guard activity == nil, operationRevision == revision, ejectedDevices == excluded else {
            refreshPending = true
            return
        }

        switch result {
        case let .success(inventory):
            if disks != inventory { disks = inventory }
            if selected == nil { selection = disks.first?.id }
            if displayingScanError { setMessage(nil) }
            if autoMount, let target = Disks.automaticCandidates(disks, remembered: remembered,
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
        if !disk.fingerprint.canRemember { return language.text("error.noIdentity") }
        if disks.contains(where: { $0.id != disk.id && $0.fingerprint == disk.fingerprint }) {
            return language.text("error.duplicateIdentity")
        }
        if !autoMount { return language.text("error.autoMountOff") }
        return nil
    }

    func setRemembered(_ enabled: Bool, diskID: UInt64) {
        guard !preview, activity == nil, let disk = disks.first(where: { $0.id == diskID }),
              automaticMountRestriction(for: disk) == nil else { return }
        var updated = remembered
        if enabled { updated.insert(disk.fingerprint) }
        else { updated.remove(disk.fingerprint) }
        do {
            try RememberedDisks.save(updated, to: defaults)
            remembered = updated
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
        guard !preview else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginStatus = SMAppService.mainApp.status
            if loginStatus == .requiresApproval {
                setMessage("settings.loginHint")
            }
        } catch {
            setMessage("error.login", error: true, diagnostic: error.localizedDescription)
        }
    }

    func openDependencyHealth() {
        dependencySheetPresented = true
        Task { await checkDependencies() }
    }

    func checkDependencies() async {
        guard !preview, !checkingDependencies else { return }
        checkingDependencies = true
        dependencyInstallError = nil
        dependencyReport = await Task.detached(priority: .utility) { Dependencies.inspect() }.value
        checkingDependencies = false
        if message == Self.checkingMountMessage || message == Self.mountNotReadyMessage {
            let ready = dependencyReport?.canMountReadWrite == true
            setMessage(ready ? nil : Self.mountNotReadyMessage, error: !ready)
        }
        await refresh()
    }

    func installDependency() {
        guard !preview, activity == nil, !checkingDependencies else { return }
        let usage = Dependencies.checkDriverUsage()
        dependencyInstallError = usage.repairBlockMessage
        guard usage == .idle else { return }
        guard let installer = Bundle.main.url(forResource: "ezNTFS-Driver", withExtension: "pkg"),
              NSWorkspace.shared.open(installer) else {
            dependencyInstallError = "health.installerError"
            return
        }
    }

    func openServiceSettings() {
        SMAppService.openSystemSettingsLoginItems()
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
        guard !preview, activity == nil, target.canMountReadWrite else { return }
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
                logger.notice("Read-write mount confirmed.")
                setMessage(InterfaceMessage("notice.mounted", arguments: [target.name]))
            } catch {
                logger.error("Read-write mount failed: \(error.localizedDescription, privacy: .public)")
                showMountFailure(error.localizedDescription)
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
        sessionAttempts.insert(target.connection)
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

    private func showMountFailure(_ detail: String) {
        let lower = detail.lowercased()
        if lower.contains("operation not permitted") || lower.contains("permission denied") {
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
                            needsDiskPermission: Bool = false) {
        displayingScanError = false
        ejectNoticeDevice = nil
        if message != text { message = text }
        if isError != error { isError = error }
        if self.diagnostic != diagnostic { self.diagnostic = diagnostic }
        if self.needsDiskPermission != needsDiskPermission { self.needsDiskPermission = needsDiskPermission }
    }
}
