import CryptoKit
import Darwin
import Foundation
import Security

public enum SystemDriver {
    public static let support = URL(fileURLWithPath: "/Library/Application Support/ezNTFS", isDirectory: true)
    public static let serviceBundle = support.appendingPathComponent("Service.app")
    public static let serviceExecutable = serviceBundle.appendingPathComponent("Contents/MacOS/ezntfs-service")
    public static let driverReceipt = support.appendingPathComponent("Driver/installed.plist")
    public static let fuseBundle = URL(fileURLWithPath: "/Library/Filesystems/macfuse.fs", isDirectory: true)
    public static let fuseHelper = fuseBundle.appendingPathComponent("Contents/Resources/mount_macfuse")
    public static let fuseFramework = fuseBundle.appendingPathComponent("Contents/Frameworks/MFMount.framework/Versions/A/MFMount")
    public static let fuseSigner = "anchor apple generic and certificate leaf[subject.OU] = \"3T5GSNBU6W\""
    public static let installLock = support.appendingPathComponent("service.lock")

    struct Receipt: Decodable {
        let build: String
        let version: String
        let macFUSEVersion: String
        let files: [String: String]

        var directory: URL {
            SystemDriver.support.appendingPathComponent("Driver", isDirectory: true)
                .appendingPathComponent(build, isDirectory: true)
        }
    }

    public static func requireDriver() throws -> String {
        try inspectDriver().path
    }

    public static func withMountLock<T>(_ mount: () throws -> T) throws -> T {
        try protectedPath(installLock)
        let lock = open(installLock.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard lock >= 0 else { throw EZError("无法检查系统驱动安装状态。") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw EZError("读写组件正在安装或挂载，请稍后再试。")
        }
        guard !FileManager.default.fileExists(atPath: support.appendingPathComponent(".installing").path) else {
            throw EZError("读写组件安装尚未完成。请运行安装器修复。")
        }
        return try mount()
    }

    static func inspectDriver() throws -> (path: String, version: String) {
        try protectedPath(driverReceipt)
        let receipt = try PropertyListDecoder().decode(Receipt.self, from: Data(contentsOf: driverReceipt))
        guard receipt.build.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]{0,63}/) != nil,
              Set(receipt.files.keys) == ["bin/ntfs-3g", "lib/libfuse.2.dylib"] else {
            throw EZError("系统驱动清单无效，请重新安装读写组件。")
        }
        let fuseVersion = try inspectFUSE()
        guard fuseVersion == receipt.macFUSEVersion else {
            throw EZError("已安装的 macFUSE 为 \(fuseVersion)，本驱动包需要 \(receipt.macFUSEVersion)。")
        }
        for (relative, expected) in receipt.files {
            let file = receipt.directory.appendingPathComponent(relative)
            try protectedPath(file)
            guard try SHA256.hash(data: Data(contentsOf: file)).map({ String(format: "%02x", $0) }).joined() == expected else {
                throw EZError("NTFS-3G 组件校验失败，请重新安装读写组件。")
            }
        }
        let driver = receipt.directory.appendingPathComponent("bin/ntfs-3g")
        guard access(driver.path, X_OK) == 0 else { throw EZError("系统驱动不可执行。") }
        return (driver.path, receipt.version)
    }

    static func inspectFUSE() throws -> String {
        try verifyCode(at: fuseHelper, requirement: fuseSigner)
        try verifyCode(at: fuseFramework, requirement: fuseSigner)
        let info = fuseBundle.appendingPathComponent("Contents/Info.plist")
        try protectedPath(info)
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: info), format: nil) as? [String: Any]
        guard let version = plist?["CFBundleShortVersionString"] as? String, !version.isEmpty else {
            throw EZError("macFUSE 安装不完整，请运行官方安装器。")
        }
        return version
    }

    // A root-owned file inside a writable directory can still be replaced.
    public static func protectedPath(_ url: URL) throws {
        let path = url.path
        let components = url.pathComponents
        guard components.first == "/", try canonicalPath(path) == path else {
            throw EZError("系统组件路径无效。")
        }
        var current = "/"
        for (index, name) in components.dropFirst().enumerated() {
            current = (current as NSString).appendingPathComponent(name)
            var attributes = stat()
            let type = attributesFor(path: current, into: &attributes)
            let isLast = index == components.count - 2
            guard attributes.st_uid == 0, attributes.st_mode & 0o022 == 0,
                  type == S_IFDIR || (isLast && type == S_IFREG),
                  !hasACL(current) else {
                throw EZError("系统组件路径的所有权或权限不安全，请修复安装。")
            }
        }
    }

    private static func attributesFor(path: String, into attributes: inout stat) -> mode_t {
        guard lstat(path, &attributes) == 0 else { return 0 }
        return attributes.st_mode & S_IFMT
    }

    private static func hasACL(_ path: String) -> Bool {
        guard let acl = acl_get_file(path, ACL_TYPE_EXTENDED) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0
    }

    public static func verifyCode(at url: URL, requirement: String) throws {
        try protectedPath(url)
        var code: SecStaticCode?
        var policy: SecRequirement?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &policy) == errSecSuccess, let policy,
              SecStaticCodeCheckValidity(code, flags, policy) == errSecSuccess else {
            throw EZError("系统组件签名不匹配，请重新安装。")
        }
    }
}
