import Darwin

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
