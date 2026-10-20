import Foundation

/// What MacReplica is busy with when the Mac must not go to sleep on its own.
public enum LongOperation: String, Sendable, CaseIterable {
    case inventory, backup, verification, restore, installerDownload, installerCopy, installerWrite
}

/// Keeps the Mac from going to sleep **when idle** while a long operation runs (macOS's own assertion, as
/// `caffeinate -i` takes it): the display may still turn off, and closing the lid still sleeps. It shows in Activity
/// Monitor (Energy › Preventing Sleep) and in `pmset -g assertions` with the reason given, and is released as soon as
/// the operation is no longer running.
public final class SleepPrevention: @unchecked Sendable {
    private let lock = NSLock()
    private var activity: NSObjectProtocol?
    public private(set) var operation: LongOperation?

    public init() {}

    /// Holds the assertion for `operation` (with this reason), or releases it for nil. Calling it again with the same
    /// operation changes nothing.
    public func update(_ operation: LongOperation?, reason: @autoclosure () -> String) {
        lock.withLock {
            guard operation != self.operation else { return }
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
            self.operation = operation
            if operation != nil {
                activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: reason())
            }
        }
    }

    public var isActive: Bool { lock.withLock { activity != nil } }

    deinit {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
}
