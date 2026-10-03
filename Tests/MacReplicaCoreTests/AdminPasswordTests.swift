import Darwin
import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// The administrator password is asked for once per restore, checked right away, and handed to every
/// `sudo` call of Homebrew through the askpass helper.
@Suite("Administrator password")
struct AdminPasswordTests {
    final class Prompts: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String?]
        private(set) var reasons: [AdminPasswordPrompt] = []
        init(_ answers: [String?]) { self.answers = answers }
        func next(_ reason: AdminPasswordPrompt) -> String? {
            lock.withLock {
                reasons.append(reason)
                return answers.isEmpty ? nil : answers.removeFirst()
            }
        }
        var count: Int { lock.withLock { reasons.count } }
    }

    struct Accepts: AdminPasswordValidating {
        var password: String
        func isValid(_ candidate: String) async -> Bool { candidate == password }
    }

    @Test func asksOnceChecksAndExplainsAWrongPassword() async {
        let prompts = Prompts(["typo", "secret"])
        let broker = AdminPasswordBroker(prompt: { prompts.next($0) }, validator: Accepts(password: "secret"))
        #expect(await broker.validatedPassword() == "secret")
        #expect(prompts.reasons == [.first, .wrongPassword], "the second dialog says the first password was wrong")
        for _ in 0..<5 { #expect(await broker.validatedPassword() == "secret") }
        #expect(prompts.count == 2, "later sudo calls do not ask again")
        await broker.forget()
        #expect(await broker.validatedPassword() == nil, "after the restore the password is gone and no answers are left")
    }

    @Test func cancellingOrThreeWrongPasswordsStopsAsking() async {
        let cancelled = Prompts([nil])
        let broker = AdminPasswordBroker(prompt: { cancelled.next($0) }, validator: Accepts(password: "secret"))
        #expect(await broker.validatedPassword() == nil)
        #expect(await broker.validatedPassword() == nil)
        #expect(cancelled.count == 1, "no new dialog after Cancel in the same restore")

        let wrong = Prompts(["a", "b", "c", "secret"])
        let limited = AdminPasswordBroker(prompt: { wrong.next($0) }, validator: Accepts(password: "secret"))
        #expect(await limited.validatedPassword() == nil)
        #expect(wrong.count == 3)
        #expect(await limited.validatedPassword() == nil)
        #expect(wrong.count == 3)
    }

    @Test func onlyRequestsWithTheTokenGetThePassword() async throws {
        let prompts = Prompts(["secret"])
        let server = try AskpassServer(broker: AdminPasswordBroker(prompt: { prompts.next($0) }, validator: Accepts(password: "secret")))
        defer { server.stop() }
        #expect(Self.request(server.socketPath, "wrong-token") == "DENY\n")
        #expect(prompts.count == 0, "a request without the token never shows a dialog")
        #expect(Self.request(server.socketPath, server.token) == "OK\tsecret\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: (server.socketPath as NSString).deletingLastPathComponent)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: server.socketPath), "the socket is removed after the restore")
    }

    static func request(_ path: String, _ token: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        let request = Array((token + "\n").utf8)
        _ = request.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 256)
        var answer = Data()
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            answer.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: answer, as: UTF8.self)
    }

    final class Marker {}

    /// The askpass helper built next to the tests.
    static var helper: URL { Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("MacReplicaAskpass") }

    /// Two casks that each run several privileged steps: the user is asked once for the whole restore, and the
    /// real helper answers every `sudo` request of both Homebrew processes with the checked password.
    @Test func oneDialogForAllHomebrewSudoCalls() async throws {
        #expect(FileManager.default.isExecutableFile(atPath: Self.helper.path))
        let sandbox = try Sandbox("admin-password")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        try fresh.setFlag("needs-admin/pixel-forge", true, content: "3")
        try fresh.setFlag("needs-admin/terminal-plus", true, content: "2")
        try fresh.setFlag("admin-password", true, content: "correct horse")
        let prompts = Prompts(["wrong", "correct horse"])
        var environment = TestEnvironment.restoreEnvironment(target, askpass: Self.helper.path)
        environment.adminPasswordValidator = target.makeAdminPasswordValidator()
        environment.adminPasswordPrompt = { prompts.next($0) }
        environment.askpassExtraEnvironment = ["MACREPLICA_ASKPASS_NO_DIALOG": "1"]
        let selection = RestoreSelection(components: [.applications])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let session = await RestoreExecutor(environment: environment, backupRoot: backup, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: backup.path, selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        #expect(session.results["cask:pixel-forge"]?.outcome == .succeeded)
        #expect(session.results["cask:terminal-plus"]?.outcome == .succeeded)
        #expect(prompts.reasons == [.first, .wrongPassword], "one dialog, repeated once because the first password was wrong")
        let calls = try String(contentsOf: fresh.state.appendingPathComponent("askpass-calls"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(calls == ["pixel-forge", "terminal-plus"], "each Homebrew process asked once and got the right password at once")
    }
}
