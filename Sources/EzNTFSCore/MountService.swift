import Darwin
import Foundation
@preconcurrency import XPC

public enum MountServiceConfiguration {
    public static let name = "local.ezntfs.mount"
    public static let path = SystemDriver.support.appendingPathComponent("service.plist")

    public static var usesFoundationTransport: Bool {
        #if EZNTFS_MONTEREY || EZNTFS_MONTEREY_PREVIEW
        return false
        #else
        if #available(macOS 13.0, *) { return true }
        return false
        #endif
    }

    public struct Identity: Decodable {
        public let clientRequirement: String
        public let serviceRequirement: String
        public let appBuild: String?

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
        if #available(macOS 13.0, *), MountServiceConfiguration.usesFoundationTransport {
            try call(timeout: 4) { proxy, reply in proxy.check(reply: reply) }
        } else {
            try callLegacy()
        }
    }

    public static func mount(_ volume: ExternalVolume) throws {
        let actual = try Disks.confirm(volume)
        if actual.isWritable { return }
        let request = try JSONEncoder().encode(MountRequest(actual))
        if #available(macOS 13.0, *), MountServiceConfiguration.usesFoundationTransport {
            try call(timeout: 60) { proxy, reply in proxy.mount(request: request, reply: reply) }
        } else {
            try callLegacy(request: request)
        }
        guard try Disks.confirm(actual).isWritable else {
            throw EZError("系统尚未确认目标卷可写。")
        }
    }

    private static func callLegacy(request: Data? = nil) throws {
        let identity = try MountServiceConfiguration.Identity.load()
        try SystemDriver.verifyCode(at: SystemDriver.serviceExecutable, requirement: identity.serviceRequirement)
        let connection = xpc_connection_create_mach_service(MountServiceConfiguration.name, nil,
                                                            UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
        try LegacyMountIPC.requirePeer(connection, identity.serviceRequirement)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_resume(connection)
        defer { xpc_connection_cancel(connection) }

        // The first round trip verifies the daemon before sending disk identifiers.
        try sendLegacy(on: connection, request: nil, timeout: 4)
        if let request { try sendLegacy(on: connection, request: request, timeout: 60) }
    }

    private static func sendLegacy(on connection: xpc_connection_t, request: Data?, timeout: TimeInterval) throws {
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "operation", request == nil ? "check" : "mount")
        if let request {
            request.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { xpc_dictionary_set_data(message, "request", base, bytes.count) }
            }
        }
        let state = Reply()
        xpc_connection_send_message_with_reply(connection, message, .global(qos: .utility)) { reply in
            guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
                state.finish("挂载服务拒绝连接或未启用。请检查后台服务，或重新安装本版本。")
                return
            }
            if xpc_dictionary_get_bool(reply, "ok") {
                state.finish(nil)
            } else {
                state.finish(xpc_dictionary_get_string(reply, "error").map { String(cString: $0) }
                             ?? "挂载服务返回了无效响应。")
            }
        }
        try state.wait(timeout: timeout)
    }

    @available(macOS 13.0, *)
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
        try state.wait(timeout: timeout)
    }

    private final class Reply: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var completed = false
        private var message: String?

        func wait(timeout: TimeInterval) throws {
            guard semaphore.wait(timeout: .now() + timeout) == .success else {
                throw EZError("挂载服务响应超时。请等待当前操作结束，再刷新硬盘状态。")
            }
            if let error = lock.withLock({ message }) { throw EZError(error) }
        }

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

public enum LegacyMountIPC {
    public static func requirePeer(_ connection: xpc_connection_t, _ requirement: String) throws {
        let status = requirement.withCString { xpc_connection_set_peer_code_signing_requirement(connection, $0) }
        guard status == 0 else { throw EZError("无法设置挂载服务的 XPC 签名校验（\(status)）。") }
    }
}
