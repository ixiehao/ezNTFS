import Foundation

public enum RememberedDisks {
    public static func load(_ defaults: UserDefaults) -> Set<DiskFingerprint> {
        let decoder = JSONDecoder()
        if let data = defaults.data(forKey: "rememberedDisks") {
            return (try? decoder.decode(Set<DiskFingerprint>.self, from: data))?.filter(\.canRemember) ?? []
        }
        guard let old = defaults.data(forKey: "targetDisk"),
              let fingerprint = try? decoder.decode(DiskFingerprint.self, from: old),
              fingerprint.canRemember else { return [] }
        return [fingerprint]
    }

    public static func save(_ fingerprints: Set<DiskFingerprint>, to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(fingerprints), forKey: "rememberedDisks")
    }

    public static func loadExclusions(_ defaults: UserDefaults) -> Set<DiskFingerprint> {
        loadStableFingerprints(defaults, key: "automaticMountExclusions")
    }

    public static func saveExclusions(_ fingerprints: Set<DiskFingerprint>, to defaults: UserDefaults) throws {
        try saveStableFingerprints(fingerprints, to: defaults, key: "automaticMountExclusions")
    }

    public static func loadRecognizedVolumes(_ defaults: UserDefaults) -> Set<DiskFingerprint> {
        loadStableFingerprints(defaults, key: "recognizedNTFSVolumes")
    }

    public static func saveRecognizedVolumes(_ fingerprints: Set<DiskFingerprint>, to defaults: UserDefaults) throws {
        try saveStableFingerprints(fingerprints, to: defaults, key: "recognizedNTFSVolumes")
    }

    private static func loadStableFingerprints(_ defaults: UserDefaults, key: String) -> Set<DiskFingerprint> {
        guard let data = defaults.data(forKey: key),
              let fingerprints = try? JSONDecoder().decode(Set<DiskFingerprint>.self, from: data) else { return [] }
        return Set(fingerprints.filter(\.canRemember))
    }

    private static func saveStableFingerprints(_ fingerprints: Set<DiskFingerprint>, to defaults: UserDefaults,
                                               key: String) throws {
        defaults.set(try JSONEncoder().encode(fingerprints.filter(\.canRemember)), forKey: key)
    }
}
