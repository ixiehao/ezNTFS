import Darwin
import Foundation
import IOKit

public enum DriverUsage: Int32, Sendable {
    case idle = 0
    case inUse = 1
    case unavailable = 2

    public static func inspect(under directory: String) -> Self {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return .unavailable }
        let capacity = Int(estimated) + 256
        var processes = [pid_t](repeating: 0, count: capacity)
        let count = processes.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard count > 0, count < capacity else { return .unavailable }

        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var unresolvedDriver = false
        for pid in processes.prefix(Int(count)) where pid > 0 {
            let length = path.withUnsafeMutableBytes {
                proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
            }
            if length > 0 {
                if belongs(cString(path), to: directory) { return .inUse }
            } else if errno != ESRCH {
                let length = name.withUnsafeMutableBytes {
                    proc_name(pid, $0.baseAddress, UInt32($0.count))
                }
                if length > 0, cString(name) == "ntfs-3g" { unresolvedDriver = true }
            }
        }
        return unresolvedDriver ? .unavailable : .idle
    }

    public static func inspectInstallation(under directory: String) -> Self {
        let driver = inspect(under: directory)
        guard driver == .idle else { return driver }
        var media: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &media) == KERN_SUCCESS else {
            return .unavailable
        }
        defer { IOObjectRelease(media) }
        while case let entry = IOIteratorNext(media), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            // A partition scheme can keep the whole disk open after its volumes have been ejected.
            guard property(entry, "BSD Name") is String, property(entry, "Open") as? Bool == true,
                  property(entry, "Whole") as? Bool != true || property(entry, "Leaf") as? Bool == true else { continue }
            guard let external = isExternal(entry) else { return .unavailable }
            if external { return .inUse }
        }
        return IOIteratorIsValid(media) != 0 ? .idle : .unavailable
    }

    private static func isExternal(_ entry: io_registry_entry_t) -> Bool? {
        if hasExternalInterconnect(entry) { return true }
        var parents: io_iterator_t = 0
        let options = IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
        guard IORegistryEntryCreateIterator(entry, kIOServicePlane, options, &parents) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parents) }
        while case let parent = IOIteratorNext(parents), parent != IO_OBJECT_NULL {
            defer { IOObjectRelease(parent) }
            if hasExternalInterconnect(parent) { return true }
        }
        return IOIteratorIsValid(parents) != 0 ? false : nil
    }

    private static func hasExternalInterconnect(_ entry: io_registry_entry_t) -> Bool {
        let connection = property(entry, "Protocol Characteristics") as? [String: Any]
        return connection?["Physical Interconnect Location"] as? String == "External"
    }

    private static func property(_ entry: io_registry_entry_t, _ name: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, name as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func belongs(_ path: String, to directory: String) -> Bool {
        let dataVolume = "/System/Volumes/Data"
        return path.hasPrefix(directory + "/") || path.hasPrefix(dataVolume + directory + "/")
    }

    private static func cString(_ bytes: [CChar]) -> String {
        bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { String(cString: $0) } ?? ""
        }
    }
}
