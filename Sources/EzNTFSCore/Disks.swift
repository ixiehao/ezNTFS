import Darwin
import DiskArbitration
import Foundation
import IOKit

public struct DiskFingerprint: Codable, Sendable, Hashable {
    public let serial: String
    public let vendor: UInt16
    public let product: UInt16
    public let partitionOffset: UInt64
    public let partitionBytes: UInt64

    public var canRemember: Bool { !serial.hasPrefix("connection:") }

    public init(serial: String, vendor: UInt16, product: UInt16, partitionOffset: UInt64, partitionBytes: UInt64) {
        self.serial = serial
        self.vendor = vendor
        self.product = product
        self.partitionOffset = partitionOffset
        self.partitionBytes = partitionBytes
    }
}

public struct ExternalVolume: Identifiable, Sendable, Equatable {
    public var id: UInt64 { connection }
    public let connection: UInt64
    public let deviceConnection: UInt64
    public let fingerprint: DiskFingerprint
    public let partition: String
    public let wholeDisk: String
    public let name: String
    public let mount: VolumeMount?
    public let fileSystemConfirmed: Bool
    public let transport: String
    let testImageOwner: uid_t?

    public var isWritable: Bool { mount?.kind == "macfuse" && mount?.readOnly == false }

    public var canMountReadWrite: Bool {
        guard let mount else { return true }
        return mount.kind == "ntfs" && mount.readOnly
    }

    public init(connection: UInt64, deviceConnection: UInt64, fingerprint: DiskFingerprint,
                partition: String, wholeDisk: String, name: String, mount: VolumeMount?,
                fileSystemConfirmed: Bool, transport: String = "USB", testImageOwner: uid_t? = nil) {
        self.connection = connection
        self.deviceConnection = deviceConnection
        self.fingerprint = fingerprint
        self.partition = partition
        self.wholeDisk = wholeDisk
        self.name = name
        self.mount = mount
        self.fileSystemConfirmed = fileSystemConfirmed
        self.transport = transport
        self.testImageOwner = testImageOwner
    }
}

public enum AutomaticMountPolicy: Sendable {
    case remembered(Set<DiskFingerprint>)
    case connectedExcept(Set<DiskFingerprint>)

    public func includes(_ fingerprint: DiskFingerprint) -> Bool {
        switch self {
        case .remembered(let disks): fingerprint.canRemember && disks.contains(fingerprint)
        case .connectedExcept(let excluded): !excluded.contains(fingerprint)
        }
    }
}

public enum Disks {
    static let diskutil = "/usr/sbin/diskutil"
    private static let partitionPattern = #"\Adisk[0-9]+(?:s[0-9]+)?\z"#
    private static let wholeDiskPattern = #"\Adisk[0-9]+\z"#

    static func isPartitionName(_ name: String) -> Bool {
        name.range(of: partitionPattern, options: .regularExpression) != nil
    }

    public static func scan(known: Set<DiskFingerprint> = [], excluding: Set<UInt64> = []) throws -> [ExternalVolume] {
        let mounts = try VolumeMount.snapshot()
        let session = DASessionCreate(nil)
        var media: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &media) == KERN_SUCCESS else {
            throw EZError("无法读取系统磁盘列表。")
        }
        defer { IOObjectRelease(media) }
        var volumes: [ExternalVolume] = []
        while case let entry = IOIteratorNext(media), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            if let volume = describe(entry, session: session, mounts: mounts, known: known, excluding: excluding) {
                volumes.append(volume)
            }
        }
        return volumes.sorted { $0.partition < $1.partition }
    }

    public static func volume(_ partition: String, known: Set<DiskFingerprint> = []) throws -> ExternalVolume {
        guard isPartitionName(partition) else {
            throw EZError("分区标识无效。")
        }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, partition))
        guard media != IO_OBJECT_NULL else { throw EZError("分区已离线。") }
        defer { IOObjectRelease(media) }
        guard let volume = describe(media, session: DASessionCreate(nil), mounts: try VolumeMount.snapshot(),
                                    known: known), volume.partition == partition else {
            throw EZError("系统未确认这是外置 NTFS 卷。请检查硬盘连接和格式。")
        }
        return volume
    }

    public static func confirm(_ volume: ExternalVolume) throws -> ExternalVolume {
        let actual = try self.volume(volume.partition, known: [volume.fingerprint])
        guard actual.fingerprint == volume.fingerprint, actual.connection == volume.connection,
              actual.deviceConnection == volume.deviceConnection, actual.wholeDisk == volume.wholeDisk,
              actual.testImageOwner == volume.testImageOwner else {
            throw EZError("设备连接已变化。请重新确认目标盘。")
        }
        return actual
    }

    public static func copyMount(for volume: ExternalVolume) throws -> MountedDisk {
        let actual = try confirm(volume)
        guard actual.isWritable, let path = actual.mount?.path else { throw EZError("目标卷未以 macFUSE 读写挂载。") }
        let mount = try MountedDisk.at(path)
        guard mount.kind == "macfuse", !mount.readOnly, mount.path == path, mount.attached(to: actual.partition) else {
            throw EZError("目标 NTFS 卷已离线或不可写。")
        }
        return mount
    }

    public static func automaticCandidates(_ volumes: [ExternalVolume], remembered: Set<DiskFingerprint>,
                                           attempted: Set<UInt64>) -> [ExternalVolume] {
        automaticCandidates(volumes, policy: .remembered(remembered), attempted: attempted)
    }

    public static func automaticCandidates(_ volumes: [ExternalVolume], policy: AutomaticMountPolicy,
                                           attempted: Set<UInt64>) -> [ExternalVolume] {
        let counts = Dictionary(grouping: volumes, by: \.fingerprint).mapValues(\.count)
        return volumes.filter {
            policy.includes($0.fingerprint) && counts[$0.fingerprint] == 1
                && $0.fileSystemConfirmed && $0.canMountReadWrite && !attempted.contains($0.connection)
        }
    }

    public static func mountAttemptsAfterWake(_ attempted: Set<UInt64>,
                                             disksBeforeSleep: [ExternalVolume]) -> Set<UInt64> {
        attempted.subtracting(disksBeforeSleep.lazy.filter(\.isWritable).map(\.connection))
    }

    public static func eject(_ volume: ExternalVolume) throws {
        try eject(volume, confirm: confirm, run: { arguments in _ = try Tool.run(diskutil, arguments) },
                  mountedDevices: { Set(try VolumeMount.snapshot().keys) })
    }

    static func eject(_ volume: ExternalVolume, confirm: (ExternalVolume) throws -> ExternalVolume,
                      run: ([String]) throws -> Void, mountedDevices: () throws -> Set<String>) throws {
        let actual = try confirm(volume)
        try run(["eject", "/dev/\(actual.wholeDisk)"])
        guard !(try mountedDevices()).contains(where: {
            $0 == actual.wholeDisk || $0.hasPrefix(actual.wholeDisk + "s")
        }) else {
            throw EZError("硬盘上仍有卷处于挂载状态。请关闭正在使用它的文件后再试。")
        }
    }

    public static func isDeviceConnected(_ connection: UInt64) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(connection))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        return IOObjectConformsTo(service, "IOUSBHostDevice") != 0
            || IOObjectConformsTo(service, "IOBlockStorageDevice") != 0
    }

    private static func describe(_ media: io_service_t, session: DASession?, mounts: [String: VolumeMount],
                                 known: Set<DiskFingerprint>, excluding: Set<UInt64> = []) -> ExternalVolume? {
        guard let partition = property(media, "BSD Name") as? String,
              isPartitionName(partition),
              let size = property(media, "Size") as? NSNumber,
              let connection = registryID(media) else { return nil }
        let whole = property(media, "Whole") as? Bool == true
        guard let storage = storageIdentity(of: media),
              !excluding.contains(storage.connection) else { return nil }
        let mount = mounts[partition]

        var offset: UInt64 = 0
        if !whole {
            guard let base = property(media, "Base") as? NSNumber else { return nil }
            offset = base.uint64Value
        }
        let fingerprint = DiskFingerprint(serial: storage.serial, vendor: storage.vendor, product: storage.product,
                                          partitionOffset: offset, partitionBytes: size.uint64Value)
        let description = session.flatMap { DADiskCreateFromIOMedia(nil, $0, media) }
            .flatMap { DADiskCopyDescription($0) as? [String: Any] }
        if storage.testImageOwner == nil, description?[kDADiskDescriptionDeviceInternalKey as String] as? Bool == true { return nil }
        let kind = description?[kDADiskDescriptionVolumeKindKey as String] as? String
        if let kind, kind != "ntfs", kind != "macfuse" { return nil }
        let confirmed = kind == "ntfs" || mount?.kind == "ntfs"
        // GPT Basic Data may also contain exFAT or FAT. A type ID alone cannot authorize a mount.
        guard confirmed || known.contains(fingerprint) else { return nil }
        let name = description?[kDADiskDescriptionVolumeNameKey as String] as? String
            ?? mount.map { URL(fileURLWithPath: $0.path).lastPathComponent }
            ?? partition
        if storage.testImageOwner != nil && !known.contains(fingerprint) && (!confirmed || name != "EZNTFS-QA") {
            return nil
        }
        return ExternalVolume(connection: connection, deviceConnection: storage.connection, fingerprint: fingerprint,
                              partition: partition, wholeDisk: storage.wholeDisk, name: name,
                              mount: mount, fileSystemConfirmed: confirmed, transport: storage.transport,
                              testImageOwner: storage.testImageOwner)
    }

    private struct StorageIdentity {
        let connection: UInt64
        let serial: String
        let vendor: UInt16
        let product: UInt16
        let wholeDisk: String
        let transport: String
        var testImageOwner: uid_t? = nil
    }

    private static func storageIdentity(of media: io_service_t) -> StorageIdentity? {
        var current = media
        defer { if current != media { IOObjectRelease(current) } }
        var wholeDisk: String?
        var deviceID: UInt64?
        var deviceSerial: String?
        var transport: String?
        while true {
            if wholeDisk == nil, IOObjectConformsTo(current, "IOMedia") != 0,
               property(current, "Whole") as? Bool == true,
               let name = property(current, "BSD Name") as? String,
               name.range(of: wholeDiskPattern, options: .regularExpression) != nil {
                wholeDisk = name
            }
            if let attributes = property(current, "Protocol Characteristics") as? [String: Any],
               attributes["Physical Interconnect Location"] as? String == "External",
               let bus = attributes["Physical Interconnect"] as? String, !bus.isEmpty {
                transport = bus
            }
            #if EZNTFS_MONTEREY_PREVIEW
            if let wholeDisk, let image = testImage(in: current, wholeDisk: wholeDisk) { return image }
            #endif
            if deviceID == nil, IOObjectConformsTo(current, "IOBlockStorageDevice") != 0 {
                deviceID = registryID(current)
                let characteristics = property(current, "Device Characteristics") as? [String: Any]
                deviceSerial = characteristics?["Serial Number"] as? String
            }
            if IOObjectConformsTo(current, "IOUSBHostDevice") != 0 {
                guard transport == "USB", let wholeDisk, let connection = registryID(current) else { return nil }
                let serial = usableSerial(property(current, "USB Serial Number") as? String)
                    ?? "connection:\(connection)"
                let vendor = (property(current, "idVendor") as? NSNumber)?.uint16Value ?? 0
                let product = (property(current, "idProduct") as? NSNumber)?.uint16Value ?? 0
                return StorageIdentity(connection: connection, serial: serial, vendor: vendor,
                                       product: product, wholeDisk: wholeDisk, transport: "USB")
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            if current != media { IOObjectRelease(current) }
            current = parent
        }
        guard let wholeDisk, let deviceID, let transport, transport != "USB",
              transport != "Virtual Interface" else { return nil }
        let serial = usableSerial(deviceSerial).map { "\(transport):" + $0 } ?? "connection:\(deviceID)"
        return StorageIdentity(connection: deviceID, serial: serial, vendor: 0, product: 0,
                               wholeDisk: wholeDisk, transport: transport)
    }

    #if EZNTFS_MONTEREY_PREVIEW
    // Preview QA recognizes only an Apple file-backed device and the private, deliberately named fixture.
    private static func testImage(in entry: io_service_t, wholeDisk: String) -> StorageIdentity? {
        guard IOObjectConformsTo(entry, "IOBlockStorageDevice") != 0,
              let attributes = property(entry, "Protocol Characteristics") as? [String: Any],
              attributes["Physical Interconnect"] as? String == "Virtual Interface",
              attributes["Physical Interconnect Location"] as? String == "File",
              let path = imagePath(attributes["Virtual Interface Location Path"]),
              path.hasPrefix("/"), let connection = registryID(entry),
              let image = PreviewTestImage.identity(of: URL(fileURLWithPath: path)) else { return nil }
        return StorageIdentity(connection: connection, serial: image.fingerprint.serial,
                               vendor: 0, product: 0, wholeDisk: wholeDisk, transport: "Test Image",
                               testImageOwner: image.owner)
    }

    private static func imagePath(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let data = value as? Data else { return nil }
        return String(data: Data(data.prefix(while: { $0 != 0 })), encoding: .utf8)
    }
    #endif

    private static func usableSerial(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.allSatisfy({ $0 == "0" }) ? nil : value
    }

    private static func registryID(_ entry: io_registry_entry_t) -> UInt64? {
        var value: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(entry, &value) == KERN_SUCCESS ? value : nil
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
