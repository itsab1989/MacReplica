import Foundation

/// Estimates the remaining restore time from the steps that already finished.
///
/// Each kind of step has a rough relative weight (installing an app takes far
/// longer than copying a font). Once real steps have finished, the observed
/// seconds per weight unit are applied to the remaining weight.
public struct ProgressEstimator: Sendable {
    private let weights: [String: Double]
    private var finished = Set<String>()
    private var observedSeconds: Double = 0
    private var observedWeight: Double = 0

    public init(items: [RestoreItem], alreadyFinished: Set<String> = []) {
        var weights: [String: Double] = [:]
        for item in items { weights[item.id] = item.kind.weight }
        self.weights = weights
        self.finished = alreadyFinished.intersection(weights.keys)
    }

    /// Records a finished step. Steps that needed no work are counted as done
    /// but do not distort the speed estimate.
    public mutating func record(itemID: String, duration: TimeInterval, didWork: Bool) {
        guard let weight = weights[itemID], finished.insert(itemID).inserted else { return }
        if didWork, duration > 0 {
            observedSeconds += duration
            observedWeight += weight
        }
    }

    public var remainingWeight: Double {
        weights.filter { !finished.contains($0.key) }.values.reduce(0, +)
    }

    public var fractionComplete: Double {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return 1 }
        return min(max(1 - remainingWeight / total, 0), 1)
    }

    /// Seconds left, or nil while there is not enough data for a sensible estimate.
    public var remainingSeconds: TimeInterval? {
        guard observedWeight > 0, observedSeconds >= 2 else { return nil }
        return remainingWeight * observedSeconds / observedWeight
    }
}
