@testable import EzNTFSCore
import Foundation
import Testing

struct IdentityTests {
    private let paired = DiskFingerprint(serial: "paired", vendor: 0x0480, product: 1,
                                         partitionOffset: 1_048_576, partitionBytes: 500_000_000)

    private func volume(_ fingerprint: DiskFingerprint, connection: UInt64, disk: String) -> ExternalVolume {
        ExternalVolume(connection: connection, deviceConnection: connection, fingerprint: fingerprint, partition: disk + "s1",
                       wholeDisk: disk, name: "TOSHIBA EXT", mount: nil, fileSystemConfirmed: true)
    }

    @Test func matchesAfterDeviceRenumbering() throws {
        let original = volume(paired, connection: 10, disk: "disk4")
        let reconnected = volume(paired, connection: 11, disk: "disk6")
        #expect(original.id != reconnected.id)
        #expect(Disks.automaticCandidates([reconnected], remembered: [paired], attempted: [original.id]) == [reconnected])
    }

    @Test func refusesIdenticalNameWithAnotherSerialOrPartition() throws {
        let other = DiskFingerprint(serial: "different", vendor: paired.vendor, product: paired.product,
                                    partitionOffset: paired.partitionOffset, partitionBytes: paired.partitionBytes)
        let otherPartition = DiskFingerprint(serial: paired.serial, vendor: paired.vendor, product: paired.product,
                                             partitionOffset: 2_097_152, partitionBytes: paired.partitionBytes)
        let observed = [volume(other, connection: 10, disk: "disk4"),
                        volume(otherPartition, connection: 11, disk: "disk6")]
        #expect(Disks.automaticCandidates(observed, remembered: [paired], attempted: []).isEmpty)
    }

    @Test func refusesAmbiguousFingerprint() {
        let observed = [volume(paired, connection: 10, disk: "disk4"),
                        volume(paired, connection: 11, disk: "disk6")]
        #expect(Disks.automaticCandidates(observed, remembered: [paired], attempted: []).isEmpty)
    }
    @Test func separatelyRemembersDisksAndPreservesAnExplicitEmptyList() throws {
        let domain = "local.ezntfs.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(try JSONEncoder().encode(paired), forKey: "targetDisk")
        #expect(RememberedDisks.load(defaults) == [paired])
        let second = DiskFingerprint(serial: "second", vendor: 1, product: 2,
                                     partitionOffset: 2_097_152, partitionBytes: 800_000_000)
        try RememberedDisks.save([paired, second], to: defaults)
        #expect(RememberedDisks.load(defaults) == [paired, second])
        try RememberedDisks.save([], to: defaults)
        #expect(RememberedDisks.load(defaults).isEmpty)
    }

    @Test func autoMountIsLimitedToConfirmedVolumesWithStableIdentity() {
        let saved = volume(paired, connection: 10, disk: "disk4")
        let unknown = ExternalVolume(
            connection: 11, deviceConnection: 12, fingerprint: paired, partition: "disk5s2",
            wholeDisk: "disk5", name: "Unconfirmed", mount: nil, fileSystemConfirmed: false
        )
        let volatile = DiskFingerprint(serial: "connection:123", vendor: 1, product: 2,
                                       partitionOffset: 0, partitionBytes: 500_000_000)
        let manual = volume(volatile, connection: 13, disk: "disk6")
        #expect(manual.canMountReadWrite)
        #expect(Disks.automaticCandidates([unknown, manual], remembered: [paired, volatile], attempted: []).isEmpty)
        #expect(Disks.automaticCandidates([saved, manual], remembered: [paired], attempted: []) == [saved])
        #expect(Disks.automaticCandidates([saved, manual], remembered: [paired], attempted: [saved.id]).isEmpty)
    }

    @Test func connectedPolicyMountsANewNTFSVolumeAndHonorsSafetyChecks() {
        let newDisk = volume(paired, connection: 10, disk: "disk4")
        let liveIdentity = DiskFingerprint(serial: "connection:15", vendor: 1, product: 2,
                                           partitionOffset: 0, partitionBytes: 500_000_000)
        let bridgeWithoutSerial = volume(liveIdentity, connection: 15, disk: "disk5")
        let unconfirmed = ExternalVolume(connection: 20, deviceConnection: 21, fingerprint: paired,
                                         partition: "disk6s1", wholeDisk: "disk6", name: "Unconfirmed",
                                         mount: nil, fileSystemConfirmed: false)
        let otherDriver = ExternalVolume(connection: 23, deviceConnection: 24, fingerprint: paired,
                                         partition: "disk7s1", wholeDisk: "disk7", name: "Other driver",
                                         mount: VolumeMount(path: "/Volumes/Fixture", kind: "ufsd_NTFS", readOnly: false),
                                         fileSystemConfirmed: true)
        #expect(Disks.automaticCandidates([newDisk, bridgeWithoutSerial], policy: .connectedExcept([]), attempted: [])
                == [newDisk, bridgeWithoutSerial])
        #expect(Disks.automaticCandidates([newDisk, bridgeWithoutSerial], policy: .connectedExcept([paired]), attempted: [15]).isEmpty)
        #expect(Disks.automaticCandidates([unconfirmed], policy: .connectedExcept([]), attempted: []).isEmpty)
        #expect(Disks.automaticCandidates([otherDriver], policy: .connectedExcept([]), attempted: []).isEmpty)
        #expect(Disks.automaticCandidates([newDisk, volume(paired, connection: 30, disk: "disk8")],
                                         policy: .connectedExcept([]), attempted: []).isEmpty)
    }

    @Test func storesStableOptOutsApartFromThePreviousRememberedDisks() throws {
        let domain = "local.ezntfs.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let volatile = DiskFingerprint(serial: "connection:15", vendor: 1, product: 2,
                                       partitionOffset: 0, partitionBytes: 500_000_000)
        try RememberedDisks.save([paired], to: defaults)
        try RememberedDisks.saveExclusions([paired, volatile], to: defaults)
        #expect(RememberedDisks.loadExclusions(defaults) == [paired])
        #expect(RememberedDisks.load(defaults) == [paired])
        try RememberedDisks.saveRecognizedVolumes([paired], to: defaults)
        #expect(RememberedDisks.loadRecognizedVolumes(defaults) == [paired])
    }

}

extension IdentityTests {
    @Test func wakeRearmsOnlyPreviouslyWritablePartitions() {
        let unmounted = volume(paired, connection: 10, disk: "disk4")
        let mounted = ExternalVolume(
            connection: unmounted.connection, deviceConnection: unmounted.deviceConnection, fingerprint: paired,
            partition: unmounted.partition, wholeDisk: unmounted.wholeDisk, name: unmounted.name,
            mount: VolumeMount(path: "/Volumes/Fixture", kind: "macfuse", readOnly: false), fileSystemConfirmed: true
        )
        let failed = volume(paired, connection: 11, disk: "disk5")
        let attempts = Disks.mountAttemptsAfterWake([10, 11, 12], disksBeforeSleep: [mounted, failed])
        #expect(attempts == [11, 12])
        #expect(Disks.automaticCandidates([unmounted], remembered: [paired], attempted: attempts) == [unmounted])
        #expect(Disks.automaticCandidates([failed], remembered: [paired], attempted: attempts).isEmpty)
    }

    @Test func autoMountDoesNotConfuseDisksReconnectingThroughTheSameHub() {
        let second = DiskFingerprint(serial: "second", vendor: paired.vendor, product: paired.product,
                                     partitionOffset: paired.partitionOffset, partitionBytes: paired.partitionBytes)
        let firstReconnected = volume(paired, connection: 20, disk: "disk6")
        let secondReconnected = volume(second, connection: 21, disk: "disk4")
        let candidates = Disks.automaticCandidates([secondReconnected, firstReconnected],
                                                    remembered: [paired, second], attempted: [10, 11, 20])
        #expect(candidates == [secondReconnected])
    }

    @Test func ejectWithAnOpenFileFailsWithoutForcingAndCanBeRetried() throws {
        let target = volume(paired, connection: 10, disk: "disk4")
        var calls = [[String]]()
        var mounted: Set<String> = ["disk4s1", "disk4s2", "disk40s1"]
        func tryEject(busy: Bool) throws {
            try Disks.eject(target, confirm: { $0 }, run: { args in
                calls.append(args)
                if busy { throw EZError("Resource busy") }
            }, mountedDevices: { mounted })
        }
        #expect(throws: EZError.self) { try tryEject(busy: true) }
        #expect(calls.count == 1)
        mounted.remove("disk4s1")
        #expect(throws: EZError.self) { try tryEject(busy: false) }
        mounted.remove("disk4s2")
        try tryEject(busy: false)
        #expect(calls == Array(repeating: ["eject", "/dev/disk4"], count: 3))
    }

    @Test func onlyNativeReadOnlyOrUnattachedVolumesCanBeMounted() {
        let original = volume(paired, connection: 10, disk: "disk4")
        #expect(original.canMountReadWrite)
        for (kind, readOnly, allowed) in [("ntfs", true, true), ("ntfs", false, false),
                                           ("macfuse", true, false), ("macfuse", false, false),
                                           ("other", true, false)] {
            let mount = VolumeMount(path: "/Volumes/Fixture", kind: kind, readOnly: readOnly)
            let observed = ExternalVolume(connection: 10, deviceConnection: 10, fingerprint: paired, partition: original.partition,
                                          wholeDisk: original.wholeDisk, name: original.name, mount: mount, fileSystemConfirmed: true)
            #expect(observed.canMountReadWrite == allowed)
        }
    }
}

extension IdentityTests {
    @Test func acceptsTheMatchingRawDeviceWithoutRelaxingImageVerification() {
        let raw = MountedDisk(source: "/dev/rdisk4s1", path: "/Volumes/Fixture",
                              kind: "macfuse", readOnly: false, device: 1)
        #expect(Mounting.matchesWritableMount(raw, source: "/dev/disk4s1", path: raw.path, partition: "disk4s1"))
        #expect(!Mounting.matchesWritableMount(raw, source: "/dev/disk4s2", path: raw.path, partition: "disk4s2"))
        #expect(!Mounting.matchesWritableMount(raw, source: raw.source, path: "/Volumes/Other", partition: "disk4s1"))
        let image = MountedDisk(source: "/private/tmp/fixture.img", path: "/Volumes/Fixture",
                                kind: "macfuse", readOnly: false, device: 2)
        #expect(Mounting.matchesWritableMount(image, source: image.source, path: image.path, partition: nil))
        #expect(!Mounting.matchesWritableMount(image, source: "/private/tmp/other.img", path: image.path, partition: nil))
        let readOnly = MountedDisk(source: raw.source, path: raw.path, kind: "macfuse", readOnly: true, device: 1)
        #expect(!Mounting.matchesWritableMount(readOnly, source: "/dev/disk4s1", path: raw.path, partition: "disk4s1"))
    }
}
