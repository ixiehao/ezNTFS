import AppKit
import DiskArbitration
import IOKit

final class DiskEvents {
    private let session: DASession
    private let usbPort: IONotificationPortRef
    private let context: Context

    private final class Context: Sendable {
        let onChange: @MainActor @Sendable () -> Void
        init(_ onChange: @escaping @MainActor @Sendable () -> Void) { self.onChange = onChange }
    }
    private var deviceRemovals: [io_iterator_t] = []
    private var volumeObservers: [any NSObjectProtocol] = []

    @MainActor
    init?(onChange: @escaping @MainActor @Sendable () -> Void) {
        guard let session = DASessionCreate(nil),
              let usbPort = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        self.session = session
        self.usbPort = usbPort
        self.context = Context(onChange)
        let context = Unmanaged.passUnretained(self.context).toOpaque()
        guard let source = IONotificationPortGetRunLoopSource(usbPort)?.takeUnretainedValue() else { return nil }
        for deviceClass in ["IOUSBHostDevice", "IOBlockStorageDevice"] {
            var iterator: io_iterator_t = IO_OBJECT_NULL
            let result = IOServiceAddMatchingNotification(
                usbPort, kIOTerminatedNotification, IOServiceMatching(deviceClass),
                { context, iterator in
                    DiskEvents.drain(iterator)
                    DiskEvents.signal(context)
                },
                context, &iterator
            )
            guard result == KERN_SUCCESS else { return nil }
            deviceRemovals.append(iterator)
            Self.drain(iterator)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)

        DARegisterDiskAppearedCallback(session, nil, { _, context in DiskEvents.signal(context) }, context)
        DARegisterDiskDisappearedCallback(session, nil, { _, context in DiskEvents.signal(context) }, context)
        DARegisterDiskDescriptionChangedCallback(
            session, nil,
            [kDADiskDescriptionVolumePathKey, kDADiskDescriptionVolumeKindKey,
             kDADiskDescriptionVolumeNameKey] as CFArray,
            { _, _, context in DiskEvents.signal(context) }, context
        )
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        let center = NSWorkspace.shared.notificationCenter
        volumeObservers = [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            }
        }
    }

    deinit {
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IONotificationPortDestroy(usbPort)
        deviceRemovals.forEach { IOObjectRelease($0) }
        let center = NSWorkspace.shared.notificationCenter
        volumeObservers.forEach(center.removeObserver)
    }

    private static func signal(_ context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        let monitor = Unmanaged<Context>.fromOpaque(context).takeUnretainedValue()
        MainActor.assumeIsolated { monitor.onChange() }
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let device = IOIteratorNext(iterator), device != IO_OBJECT_NULL {
            IOObjectRelease(device)
        }
    }
}
