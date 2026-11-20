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
}
