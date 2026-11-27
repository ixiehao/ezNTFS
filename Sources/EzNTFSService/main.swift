import Darwin
import EzNTFSCore
import Foundation
import OSLog
import SystemConfiguration
@preconcurrency import XPC

@main
enum Service {
    static func main() {
        let logger = Logger(subsystem: "local.ezntfs.mount", category: "service")
        do {
            guard geteuid() == 0 else { throw EZError("挂载服务必须由系统启动。") }
            let identity = try MountServiceConfiguration.Identity.load()
            try SystemDriver.verifyCode(at: SystemDriver.serviceExecutable, requirement: identity.serviceRequirement)
            if #available(macOS 13.0, *), MountServiceConfiguration.usesFoundationTransport {
                let delegate = Listener()
                let listener = NSXPCListener(machServiceName: MountServiceConfiguration.name)
                listener.setConnectionCodeSigningRequirement(identity.clientRequirement)
                listener.delegate = delegate
                listener.resume()
                withExtendedLifetime((listener, delegate)) { dispatchMain() }
            } else {
                let listener = try startLegacyListener(requirement: identity.clientRequirement)
                withExtendedLifetime(listener) { dispatchMain() }
            }
        } catch {
            logger.error("Could not start mount service: \(error.localizedDescription, privacy: .public)")
            exit(1)
        }
    }

    private static func startLegacyListener(requirement: String) throws -> xpc_connection_t {
        let listener = xpc_connection_create_mach_service(MountServiceConfiguration.name, nil,
                                                          UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        try LegacyMountIPC.requirePeer(listener, requirement)
        let operations = DispatchQueue(label: "local.ezntfs.mount.operations")
        xpc_connection_set_event_handler(listener) { event in
            guard xpc_get_type(event) == XPC_TYPE_CONNECTION,
                  (try? LegacyMountIPC.requirePeer(event, requirement)) != nil else { return }
            xpc_connection_set_event_handler(event) { message in
                guard xpc_get_type(message) == XPC_TYPE_DICTIONARY,
                      let peer = xpc_dictionary_get_remote_connection(message),
                      let response = xpc_dictionary_create_reply(message) else { return }
                let user = xpc_connection_get_euid(peer)
                guard user != 0 else { return }
                let operation = xpc_dictionary_get_string(message, "operation").map { String(cString: $0) }
                let operationHandler = Operations(user: user, queue: operations)
                let reply = LegacyReply(peer: peer, response: response)
                switch operation {
                case "check":
                    operationHandler.check(reply: reply.send)
                case "mount":
                    var size = 0
                    guard let bytes = xpc_dictionary_get_data(message, "request", &size), (1...4096).contains(size) else {
                        reply.send("挂载请求数据无效。")
                        return
                    }
                    operationHandler.mount(request: Data(bytes: bytes, count: size), reply: reply.send)
                default:
                    reply.send("挂载请求类型无效。")
                }
            }
            xpc_connection_resume(event)
        }
        xpc_connection_resume(listener)
        return listener
    }
}

// Each reply is sent exactly once. The XPC objects are retained until the serial operation finishes.
private struct LegacyReply: @unchecked Sendable {
    let peer: xpc_connection_t
    let response: xpc_object_t

    func send(_ error: String?) {
        xpc_dictionary_set_bool(response, "ok", error == nil)
        if let error { xpc_dictionary_set_string(response, "error", error) }
        xpc_connection_send_message(peer, response)
    }
}

private final class Listener: NSObject, NSXPCListenerDelegate {
    private let operations = DispatchQueue(label: "local.ezntfs.mount.operations")

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier != 0 else { return false }
        connection.exportedInterface = NSXPCInterface(with: EzNTFSMountService.self)
        connection.exportedObject = Operations(user: connection.effectiveUserIdentifier, queue: operations)
        connection.resume()
        return true
    }
}

private final class Operations: NSObject, EzNTFSMountService, Sendable {
    private let user: uid_t
    private let queue: DispatchQueue

    init(user: uid_t, queue: DispatchQueue) {
        self.user = user
        self.queue = queue
    }

    func check(reply: @escaping @Sendable (String?) -> Void) {
        perform(reply) { _, _ in }
    }

    func mount(request: Data, reply: @escaping @Sendable (String?) -> Void) {
        perform(reply) { uid, gid in
            guard request.count <= 4096 else { throw EZError("挂载请求数据过长。") }
            let target = try JSONDecoder().decode(MountRequest.self, from: request)
            try SystemDriver.withMountLock {
                try Mounting.privilegedMount(partition: target.partition, connection: target.connection,
                                             deviceConnection: target.deviceConnection,
                                             fingerprint: target.fingerprint, uid: uid, gid: gid)
            }
        }
    }

    private func perform(_ reply: @escaping @Sendable (String?) -> Void,
                         operation: @escaping @Sendable (uid_t, gid_t) throws -> Void) {
        queue.async { [user] in
            do {
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard let account = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid),
                      account as String != "loginwindow", uid == user else {
                    throw EZError("只有当前在这台 Mac 上登录的用户可以挂载外置盘。")
                }
                try operation(uid, gid)
                reply(nil)
            } catch {
                reply(error.localizedDescription)
            }
        }
    }
}
