import Foundation
import Testing
@testable import MacReplicaCore

/// The tester's progress screen of a continued restore with 1.1.13 (2026-11-04, TEST1113-001…004): "23 / 585" next to
/// "Successful: 570", a cask shown green while it was being reinstalled, the bar standing at 97 %, and Details showing
/// the lines of an earlier step.
@Suite("Restore progress screen")
struct RestoreProgressStateTests {
    func item(_ id: String, _ kind: RestoreItemKind = .cask) -> RestoreItem {
        RestoreItem(id: id, kind: kind, title: id, identifier: id)
    }

    /// 20 fonts and 3 casks; the fonts and two casks finished in an earlier run.
    func continued() -> (RestoreProgressState, [RestoreItem]) {
        let items = (1...20).map { item("font:\($0)", .font) } + [item("cask:a"), item("cask:b"), item("cask:c")]
        var state = RestoreProgressState()
        state.total = items.count
        state.estimator = ProgressEstimator(items: items, alreadyFinished: Set(items.prefix(22).map(\.id)))
        for entry in items.prefix(22) {
            let result = ItemResult(itemID: entry.id, outcome: .alreadyPresent)
            state.finished.append((entry, result))
            state.count(result.outcome)
        }
        return (state, items)
    }

    @Test("A step that runs again is taken out of the finished ones and counted once when it finishes")
    func rerunStep() {
        var (state, items) = continued()
        let a = items[20]
        #expect(state.done == 22 && state.succeeded == 22)
        let before = state.fraction
        state.apply(.started(item: a, index: 20, total: 23), title: \.title)
        #expect(!state.finished.contains { $0.item.id == a.id }, "not green while it runs again")
        #expect(state.succeeded == 21 && state.done == 21)
        #expect(state.fraction < before, "counted as open again, so the bar can move")
        state.apply(.finished(item: a, result: ItemResult(itemID: a.id, outcome: .succeeded, duration: 30), index: 20, total: 23), title: \.title)
        #expect(state.finished.filter { $0.item.id == a.id }.count == 1)
        #expect(state.succeeded == 22 && state.done == 22)
        #expect(state.fraction == before)
        // A failed earlier result is taken back the same way.
        var failed = RestoreProgressState()
        failed.finished = [(a, ItemResult(itemID: a.id, outcome: .failed(RestoreFailure(category: .network, technicalDetail: ""))))]
        failed.count(failed.finished[0].result.outcome)
        failed.apply(.started(item: a, index: 0, total: 1), title: \.title)
        #expect(failed.failed == 0 && failed.finished.isEmpty)
        var skipped = RestoreProgressState()
        skipped.finished = [(a, ItemResult(itemID: a.id, outcome: .skipped(.userSkipped)))]
        skipped.count(skipped.finished[0].result.outcome)
        skipped.apply(.started(item: a, index: 0, total: 1), title: \.title)
        #expect(skipped.skipped == 0 && skipped.finished.isEmpty)
    }

    @Test("The counter is the number of steps done, the same as the counts below it")
    func doneCounter() {
        var (state, items) = continued()
        state.apply(.started(item: items[22], index: 22, total: 23), title: \.title)
        #expect(state.position == 23, "the plan position")
        #expect(state.done == 22, "what the screen shows")
        state.apply(.finished(item: items[22], result: ItemResult(itemID: "cask:c", outcome: .failed(RestoreFailure(category: .network, technicalDetail: ""))), index: 22, total: 23), title: \.title)
        #expect(state.done == 23 && state.failed == 1)
    }

    @Test("Details: a heading before each step's first line, none for steps without output, other steps' lines ignored")
    func outputHeadings() {
        var state = RestoreProgressState()
        let a = item("cask:a"), font = item("font:1", .font), b = item("cask:b")
        state.apply(.started(item: a, index: 0, total: 3), title: { "A \($0.id)" })
        state.apply(.output(itemID: a.id, line: "==> Downloading a"), title: { "A \($0.id)" })
        state.apply(.output(itemID: a.id, line: "==> Installing a"), title: { "A \($0.id)" })
        state.apply(.finished(item: a, result: ItemResult(itemID: a.id, outcome: .succeeded), index: 0, total: 3), title: { "A \($0.id)" })
        state.apply(.started(item: font, index: 1, total: 3), title: { "A \($0.id)" })
        state.apply(.finished(item: font, result: ItemResult(itemID: font.id, outcome: .succeeded), index: 1, total: 3), title: { "A \($0.id)" })
        state.apply(.started(item: b, index: 2, total: 3), title: { "A \($0.id)" })
        state.apply(.output(itemID: a.id, line: "late line of a"), title: { "A \($0.id)" })
        #expect(state.lastOutput == nil, "a new step starts without the previous step's line")
        state.apply(.output(itemID: b.id, line: "==> Fetching b"), title: { "A \($0.id)" })
        #expect(state.output.map(\.line) == ["— A cask:a —", "==> Downloading a", "==> Installing a", "— A cask:b —", "==> Fetching b"])
        #expect(state.output.map(\.id) == [1, 2, 3, 4, 5], "headings get running numbers too")
        #expect(state.lastOutput == "==> Fetching b")
        state.apply(.completed(RestoreSummary(results: [], total: 3)), title: { "A \($0.id)" })
        #expect(state.currentItem == nil)
    }

    @Test("Details keeps the newest 300 lines; the running number keeps growing so the view keeps following")
    func outputLimit() {
        var state = RestoreProgressState()
        for n in 1...305 { state.addOutput("line \(n)") }
        #expect(state.output.count == RestoreProgressState.outputLimit)
        #expect(state.outputCount == 305)
        #expect(state.output.first?.line == "line 6" && state.output.last?.id == 305)
    }

    @Test("A new state is not stopping and has no heading waiting; work done feeds the time estimate")
    func defaultsAndEstimate() {
        let fresh = RestoreProgressState()
        #expect(!fresh.stopping && !fresh.headingPending && fresh.done == 0 && fresh.fraction == 0)
        let a = item("cask:a"), b = item("cask:b"), c = item("cask:c")
        var state = RestoreProgressState()
        state.total = 3
        state.estimator = ProgressEstimator(items: [a, b, c])
        state.apply(.finished(item: a, result: ItemResult(itemID: a.id, outcome: .alreadyPresent, duration: 30), index: 0, total: 3), title: \.title)
        #expect(state.estimator.remainingSeconds == nil, "nothing was installed: no speed to estimate from")
        state.apply(.finished(item: b, result: ItemResult(itemID: b.id, outcome: .succeeded, duration: 30), index: 1, total: 3), title: \.title)
        #expect(state.estimator.remainingSeconds == 30, "one cask took 30 s, one is left")
        var failing = RestoreProgressState()
        failing.estimator = ProgressEstimator(items: [a, b])
        failing.apply(.finished(item: a, result: ItemResult(itemID: a.id, outcome: .failed(RestoreFailure(category: .network, technicalDetail: "")), duration: 20),
                                index: 0, total: 2), title: \.title)
        #expect(failing.estimator.remainingSeconds == 20, "a failed attempt also took time")
    }

    @Test("Activity is taken over")
    func activity() {
        var state = RestoreProgressState()
        state.apply(.activity(itemID: "x", .installing), title: \.title)
        #expect(state.activity == .installing)
    }

    @Test("Reopened steps count as still to do from the start; every finished one moves the counts and the lists")
    func reopenedCountUp() {
        let fonts = (1...3).map { item("font:\($0)", .font) }
        let a = item("cask:a"), b = item("cask:b"), c = item("cask:c")
        let items = fonts + [a, b, c]
        var results: [String: ItemResult] = [:]
        for entry in fonts + [a, b] { results[entry.id] = ItemResult(itemID: entry.id, outcome: .alreadyPresent) }
        var state = RestoreProgressState(items: items, results: results, alreadyFinished: Set(results.keys))
        #expect(state.total == 6 && state.done == 5 && state.succeeded == 5)
        #expect(state.pending.map(\.id) == ["cask:c"])
        state.apply(.reopened(itemIDs: ["cask:a", "cask:b", "cask:unknown"]), title: \.title)
        #expect(state.done == 3 && state.succeeded == 3, "counted as still to do from the start")
        #expect(Set(state.pending.map(\.id)) == ["cask:a", "cask:b", "cask:c"])
        #expect(!state.finished.contains { $0.item.id == "cask:a" })
        let start = state.fraction
        state.apply(.started(item: a, index: 3, total: 6), title: \.title)
        #expect(!state.pending.contains { $0.id == "cask:a" }, "running, not waiting")
        state.apply(.finished(item: a, result: ItemResult(itemID: a.id, outcome: .succeeded, duration: 60), index: 3, total: 6), title: \.title)
        #expect(state.done == 4 && state.succeeded == 4, "each finished install counts up")
        #expect(state.fraction > start)
        #expect(state.finished.last?.item.id == "cask:a")
        state.apply(.finished(item: b, result: ItemResult(itemID: b.id, outcome: .succeeded, duration: 60), index: 4, total: 6), title: \.title)
        #expect(state.pending.map(\.id) == ["cask:c"])
        #expect(state.done == 5)
    }

    @Test("A step that runs a tool shows its heading at once; a quiet step without a tool adds none")
    func headingsAtOnce() {
        var state = RestoreProgressState()
        let x = item("cask:xquartz"), y = item("cask:yed"), font = item("font:1", .font)
        state.apply(.started(item: x, index: 0, total: 3), title: \.title)
        state.apply(.output(itemID: x.id, line: "==> Fetching downloads for: xquartz"), title: \.title)
        state.apply(.finished(item: x, result: ItemResult(itemID: x.id, outcome: .succeeded), index: 0, total: 3), title: \.title)
        state.apply(.started(item: y, index: 1, total: 3), title: \.title)
        #expect(state.output.last?.line == "— cask:yed —", "the newest entry names the running step before it prints anything")
        #expect(state.lastOutput == nil)
        state.apply(.finished(item: y, result: ItemResult(itemID: y.id, outcome: .succeeded), index: 1, total: 3), title: \.title)
        let count = state.outputCount
        state.apply(.started(item: font, index: 2, total: 3), title: \.title)
        #expect(state.outputCount == count, "no heading for a font")
        #expect(RestoreProgressState.runsTool(.formula) && RestoreProgressState.runsTool(.pythonEnvironment) && !RestoreProgressState.runsTool(.font))
        #expect(RestoreProgressState.runsTool(.commandLineTools) && RestoreProgressState.runsTool(.homebrew) && RestoreProgressState.runsTool(.tap))
        #expect(RestoreProgressState.runsTool(.masTool) && RestoreProgressState.runsTool(.toolchainStep) && !RestoreProgressState.runsTool(.applicationData))
        // The heading also respects the 300-line limit.
        var full = RestoreProgressState()
        for n in 1...300 { full.addOutput("line \(n)") }
        full.apply(.started(item: x, index: 0, total: 1), title: \.title)
        #expect(full.output.count == RestoreProgressState.outputLimit && full.output.last?.line == "— cask:xquartz —")
    }
}
