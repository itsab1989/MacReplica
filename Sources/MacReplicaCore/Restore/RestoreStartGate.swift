import Foundation

/// One check before a restore and one restore at a time, however often Start is clicked. Until 1.1.12 every click
/// started another check, and each finished check could start a restore of the same steps (tester, 2026-11-03).
public struct RestoreStartGate: Sendable, Equatable {
    public private(set) var checking = false
    public private(set) var restoring = false

    public init() {}

    /// False while a check or a restore runs: the request is ignored.
    public mutating func beginCheck() -> Bool {
        guard !checking, !restoring else { return false }
        checking = true
        return true
    }

    public mutating func endCheck() { checking = false }

    /// False while a restore runs. Starting a restore ends the check that led to it.
    public mutating func beginRestore() -> Bool {
        guard !restoring else { return false }
        restoring = true
        checking = false
        return true
    }

    public mutating func endRestore() { restoring = false }
}
