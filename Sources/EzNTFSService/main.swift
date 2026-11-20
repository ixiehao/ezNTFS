import Darwin
import EzNTFSCore
import Foundation
import OSLog
import SystemConfiguration

@main
enum Service {
    static func main() {
        let logger = Logger(subsystem: "local.ezntfs.mount", category: "service")
        do {
            guard geteuid() == 0 else { throw EZError("挂载服务必须由系统启动。") }
            let identity = try MountServiceConfiguration.Identity.load()
            try SystemDriver.verifyCode(at: SystemDriver.serviceExecutable, requirement: identity.serviceRequirement)
            let delegate = Listener()
            let listener = NSXPCListener(machServiceName: MountServiceConfiguration.name)
            listener.setConnectionCodeSigningRequirement(identity.clientRequirement)
            listener.delegate = delegate
            listener.resume()
            withExtendedLifetime((listener, delegate)) { dispatchMain() }
        } catch {
            logger.error("Could not start mount service: \(error.localizedDescription, privacy: .public)")
            exit(1)
        }
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
