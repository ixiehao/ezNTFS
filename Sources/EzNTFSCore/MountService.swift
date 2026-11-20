import Darwin
import Foundation

public enum MountServiceConfiguration {
    public static let name = "local.ezntfs.mount"
    public static let path = SystemDriver.support.appendingPathComponent("service.plist")

    public struct Identity: Decodable {
        public let clientRequirement: String
        public let serviceRequirement: String

        public static func load() throws -> Self {
            try SystemDriver.protectedPath(MountServiceConfiguration.path)
            return try PropertyListDecoder().decode(Self.self, from: Data(contentsOf: MountServiceConfiguration.path))
        }
    }
}

public struct MountRequest: Codable, Sendable {
    public let partition: String
    public let connection: UInt64
    public let deviceConnection: UInt64
    public let fingerprint: DiskFingerprint

    init(_ volume: ExternalVolume) {
        partition = volume.partition
        connection = volume.connection
        deviceConnection = volume.deviceConnection
        fingerprint = volume.fingerprint
    }
}

@objc public protocol EzNTFSMountService {
    func check(reply: @escaping @Sendable (String?) -> Void)
    func mount(request: Data, reply: @escaping @Sendable (String?) -> Void)
}

public enum MountServiceClient {
    public static func check() throws {
        try call(timeout: 4) { proxy, reply in proxy.check(reply: reply) }
    }

    public static func mount(_ volume: ExternalVolume) throws {
        let actual = try Disks.confirm(volume)
        if actual.isWritable { return }
        let request = try JSONEncoder().encode(MountRequest(actual))
        try call(timeout: 60) { proxy, reply in proxy.mount(request: request, reply: reply) }
        guard try Disks.confirm(actual).isWritable else {
            throw EZError("系统尚未确认目标卷可写。")
        }
    }

    private static func call(timeout: TimeInterval,
                             invoke: (EzNTFSMountService, @escaping @Sendable (String?) -> Void) -> Void) throws {
        let identity = try MountServiceConfiguration.Identity.load()
        try SystemDriver.verifyCode(at: SystemDriver.serviceExecutable, requirement: identity.serviceRequirement)
        let connection = NSXPCConnection(machServiceName: MountServiceConfiguration.name, options: .privileged)
        connection.setCodeSigningRequirement(identity.serviceRequirement)
        connection.remoteObjectInterface = NSXPCInterface(with: EzNTFSMountService.self)
        let state = Reply()
        connection.interruptionHandler = {
            state.finish("挂载服务连接中断，请刷新硬盘状态。")
        }
        connection.invalidationHandler = {
            state.finish("无法连接挂载服务。请检查后台服务是否允许，或重新安装本版本。")
        }
        connection.resume()
        defer { connection.invalidate() }

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            state.finish("挂载服务拒绝连接或未启用。请检查后台服务，或重新安装本版本。")
        }) as? EzNTFSMountService else { throw EZError("挂载服务接口不可用。") }

        invoke(proxy, state.finish)
        guard state.semaphore.wait(timeout: .now() + timeout) == .success else {
            throw EZError("挂载服务响应超时。请等待当前操作结束，再刷新硬盘状态。")
        }
        if let error = state.error { throw EZError(error) }
    }

    private final class Reply: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var completed = false
        private var message: String?

        var error: String? { lock.withLock { message } }

        func finish(_ error: String?) {
            lock.withLock {
                guard !completed else { return }
                completed = true
                message = error
                semaphore.signal()
            }
        }
    }
}
