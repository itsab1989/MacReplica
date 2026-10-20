import DiskArbitration
import Foundation

/// Tells the installer tool when disks appear, disappear or change (DiskArbitration, which also reports drives
/// macOS cannot mount). Events are collected for a moment so that one plugged-in drive causes one new scan.
final class DriveWatcher {
    private var session: DASession?
    private let onChange: @MainActor () -> Void
    private var pending: DispatchWorkItem?

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard session == nil, let session = DASessionCreate(kCFAllocatorDefault) else { return }
        self.session = session
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { _, context in DriveWatcher.from(context)?.changed() }, context)
        DARegisterDiskDisappearedCallback(session, nil, { _, context in DriveWatcher.from(context)?.changed() }, context)
        DARegisterDiskDescriptionChangedCallback(session, nil, nil, { _, _, context in DriveWatcher.from(context)?.changed() }, context)
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        // Registering reports every disk that is already there once; that first burst is not a change.
        pending?.cancel()
        ignoreUntil = Date().addingTimeInterval(1)
    }

    func stop() {
        pending?.cancel()
        pending = nil
        guard let session else { return }
        DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.session = nil
    }

    deinit { stop() }

    private var ignoreUntil = Date.distantPast

    private static func from(_ context: UnsafeMutableRawPointer?) -> DriveWatcher? {
        context.map { Unmanaged<DriveWatcher>.fromOpaque($0).takeUnretainedValue() }
    }

    private func changed() {
        guard Date() >= ignoreUntil else { return }
        pending?.cancel()
        let work = DispatchWorkItem { [onChange] in Task { @MainActor in onChange() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
