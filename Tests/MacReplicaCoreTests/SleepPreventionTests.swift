import Foundation
import Testing
@testable import MacReplicaCore

/// While a long operation runs, macOS really holds MacReplica's “no idle sleep” assertion – checked in macOS's own
/// list (`pmset -g assertions`) – and it is gone as soon as the operation ends.
@Suite("Sleep prevention", .serialized)
struct SleepPreventionTests {
    static func assertions() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// The lines of this test process's assertions.
    static func ours() -> [String] {
        assertions().split(whereSeparator: \.isNewline).map(String.init).filter { $0.contains("pid \(getpid())(") }
    }

    @Test func theAssertionIsHeldOnlyWhileTheOperationRuns() {
        let prevention = SleepPrevention()
        let reason = "MacReplica test \(UUID().uuidString)"
        #expect(!prevention.isActive)
        prevention.update(.restore, reason: reason)
        #expect(prevention.isActive && prevention.operation == .restore)
        #expect(Self.ours().contains { $0.contains("PreventUserIdleSystemSleep") && $0.contains(reason) })

        // The same operation again changes nothing; another one replaces it.
        prevention.update(.restore, reason: "not used")
        #expect(!Self.ours().contains { $0.contains("not used") })
        let next = "MacReplica test next \(UUID().uuidString)"
        prevention.update(.installerWrite, reason: next)
        #expect(Self.ours().contains { $0.contains(next) })
        #expect(!Self.ours().contains { $0.contains(reason) })

        prevention.update(nil, reason: "")
        #expect(!prevention.isActive && prevention.operation == nil)
        #expect(!Self.ours().contains { $0.contains(next) })
    }

    @Test func aPreventionThatGoesAwayReleasesItsAssertion() {
        let reason = "MacReplica test released \(UUID().uuidString)"
        do {
            let prevention = SleepPrevention()
            prevention.update(.backup, reason: reason)
            #expect(Self.ours().contains { $0.contains(reason) })
        }
        #expect(!Self.ours().contains { $0.contains(reason) })
    }
}
