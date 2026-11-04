import Foundation

/// What the restore screen shows while a restore runs.
public struct RestoreProgressState {
    public init() {}

    public var total = 0
    public var position = 0
    public var currentItem: RestoreItem?
    public var activity: RestoreActivity = .checking
    public var succeeded = 0
    public var failed = 0
    public var skipped = 0
    public var finished: [(item: RestoreItem, result: ItemResult)] = []
    public var estimator = ProgressEstimator(items: [])
    public var stopping = false
    /// Steps of the plan that have not run yet (also those opened again when a restore continues), in plan order.
    public var pending: [RestoreItem] = []
    /// The latest lines of output from the tool working on the current step (Homebrew's downloads and installs),
    /// each with a running number that keeps growing (the list itself stays at `outputLimit` lines).
    public var output: [(id: Int, line: String)] = []
    public var outputCount = 0
    public var lastOutput: String?
    /// The current step has not printed anything yet; its heading comes before its first line.
    public var headingPending = false
    public static let outputLimit = 300

    /// Steps done so far (succeeded, failed or skipped), shown as "done / total" – the same numbers as the counts below
    /// it, also when a restore continues (until 1.1.13 the bar showed the plan position: "23 / 585" next to 570
    /// successful, tester 2026-11-04).
    public var done: Int { succeeded + failed + skipped }

    /// Weighted by how long each kind of step usually takes (an app install counts far more than a font), so the bar
    /// does not stand still through slow downloads and race through quick copies.
    public var fraction: Double { total == 0 ? 0 : estimator.fractionComplete }

    public mutating func addOutput(_ line: String) {
        outputCount += 1
        output.append((outputCount, line))
        if output.count > Self.outputLimit { output.removeFirst(output.count - Self.outputLimit) }
        lastOutput = line
    }

    /// Takes a step out of the finished ones while it runs again, so it is neither green nor counted twice.
    public mutating func reopen(_ itemID: String) {
        guard let earlier = finished.firstIndex(where: { $0.item.id == itemID }) else { return }
        let outcome = finished[earlier].result.outcome
        if outcome.isSuccessLike { succeeded -= 1 } else if outcome.isFailure { failed -= 1 } else { skipped -= 1 }
        finished.remove(at: earlier)
        estimator.reopen(itemID: itemID)
    }

    /// The state at the start of a run: the steps finished earlier, the ones still to do.
    public init(items: [RestoreItem], results: [String: ItemResult], alreadyFinished: Set<String>) {
        total = items.count
        estimator = ProgressEstimator(items: items, alreadyFinished: alreadyFinished)
        for item in items {
            if let result = results[item.id] {
                finished.append((item, result))
                count(result.outcome)
            } else {
                pending.append(item)
            }
        }
    }

    /// Steps whose tool prints output (Homebrew, Python, toolchains).
    public static func runsTool(_ kind: RestoreItemKind) -> Bool {
        switch kind {
        case .commandLineTools, .homebrew, .tap, .masTool, .formula, .cask, .pythonEnvironment, .toolchainStep: return true
        default: return false
        }
    }

    /// Counts a result that is already known (a step finished in an earlier run).
    public mutating func count(_ outcome: ItemOutcome) {
        if outcome.isSuccessLike { succeeded += 1 } else if outcome.isFailure { failed += 1 } else { skipped += 1 }
    }

    /// Applies an event of the running restore. `title` names a step for the headings in Details.
    public mutating func apply(_ event: RestoreEvent, title: (RestoreItem) -> String) {
        switch event {
        case .reopened(let itemIDs):
            for id in itemIDs {
                guard let item = finished.first(where: { $0.item.id == id })?.item else { continue }
                reopen(id)
                if !pending.contains(where: { $0.id == id }) { pending.append(item) }
            }
        case .started(let item, let index, let total):
            reopen(item.id)
            pending.removeAll { $0.id == item.id }
            currentItem = item
            position = index + 1
            self.total = total
            activity = .checking
            lastOutput = nil
            // A step that runs a tool gets its heading at once, so Details never shows the previous step's lines as the
            // newest while this one is still quiet (tester, 2026-11-04: "fetching xquartz" while yEd ran).
            if Self.runsTool(item.kind) {
                headingPending = false
                output.append((outputCount + 1, "— \(title(item)) —"))
                outputCount += 1
                if output.count > Self.outputLimit { output.removeFirst(output.count - Self.outputLimit) }
            } else {
                headingPending = true
            }
        case .activity(_, let activity):
            self.activity = activity
        case .finished(let item, let result, _, _):
            reopen(item.id)
            pending.removeAll { $0.id == item.id }
            finished.append((item, result))
            count(result.outcome)
            estimator.record(itemID: item.id, duration: result.duration, didWork: result.outcome == .succeeded || result.outcome.isFailure)
        case .output(let itemID, let line):
            guard let item = currentItem, item.id == itemID else { return }
            // Details shows which step the lines belong to: a heading before the first line of each step.
            if headingPending {
                headingPending = false
                // Details only: the step's own line follows at once and becomes the current one.
                output.append((outputCount + 1, "— \(title(item)) —"))
                outputCount += 1
            }
            addOutput(line)
        case .completed:
            currentItem = nil
        }
    }
}
