import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

@Suite("Security")
struct SecurityTests {
    @Test func commandPolicyAllowsOnlyListedAbsolutePaths() throws {
        let policy = CommandPolicy(allowedExecutables: ["/opt/homebrew/bin/brew"])
        try policy.validate(Command(executable: "/opt/homebrew/bin/brew", arguments: ["list"]))
        for executable in ["brew", "/bin/sh", "/bin/bash", "/opt/homebrew/bin/../../../bin/sh", "/usr/bin/env", ""] {
            #expect(throws: CommandError.notAllowed(executable)) { try policy.validate(Command(executable: executable)) }
        }
        #expect(throws: CommandError.invalidArgument("a\0b")) {
            try policy.validate(Command(executable: "/opt/homebrew/bin/brew", arguments: ["a\0b"]))
        }
        #expect(throws: CommandError.invalidArgument("A=B")) {
            try policy.validate(Command(executable: "/opt/homebrew/bin/brew", environment: ["A=B": "x"]))
        }
    }

    @Test(arguments: [CPUArchitecture.arm64, .x86_64])
    func liveAllowlistContainsNoShells(_ architecture: CPUArchitecture) {
        let allowed = SystemLayout.live(architecture: architecture).allowedExecutables
        for shell in ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/env", "/usr/bin/curl", "/bin/rm"] {
            #expect(!allowed.contains(shell))
        }
        // Apple silicon Macs may have Homebrew in either location (Rosetta installs); Intel Macs only in /usr/local.
        #expect(allowed.contains("/opt/homebrew/bin/brew") == (architecture == .arm64))
        #expect(allowed.contains("/usr/local/bin/brew"))
    }

    @Test func runnerRefusesDisallowedExecutablesBeforeLaunching() async throws {
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: ["/usr/bin/true"]), baseEnvironment: [:])
        await #expect(throws: CommandError.notAllowed("/bin/sh")) { _ = try await runner.run(Command(executable: "/bin/sh", arguments: ["-c", "id"])) }
        let missing = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: ["/nonexistent/tool"]), baseEnvironment: [:])
        await #expect(throws: CommandError.notExecutable("/nonexistent/tool")) { _ = try await missing.run(Command(executable: "/nonexistent/tool")) }
    }

    @Test func runnerPassesArgumentsVerbatimWithoutShellExpansion() async throws {
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: ["/bin/echo"]), baseEnvironment: ["PATH": "/usr/bin:/bin"])
        let result = try await runner.run(Command(executable: "/bin/echo", arguments: ["$(whoami)", "; rm -rf /", "`id`", "*"]))
        #expect(result.succeeded)
        #expect(result.stdout == "$(whoami) ; rm -rf / `id` *\n")
    }

    @Test func runnerUsesOnlyTheGivenEnvironment() async throws {
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: ["/usr/bin/env"]), baseEnvironment: ["PATH": "/usr/bin", "ONLY": "this"])
        let result = try await runner.run(Command(executable: "/usr/bin/env", environment: ["EXTRA": "1"]))
        let keys = Set(result.stdout.split(separator: "\n").compactMap { $0.split(separator: "=").first.map(String.init) })
        #expect(keys == ["PATH", "ONLY", "EXTRA"])
    }

    @Test func runnerTimesOutAndStreamsLines() async throws {
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: ["/bin/sleep", "/bin/ls"]), baseEnvironment: [:])
        let slow = try await runner.run(Command(executable: "/bin/sleep", arguments: ["5"], timeout: 0.3))
        #expect(slow.timedOut && !slow.succeeded)
        final class Lines: @unchecked Sendable { var values: [String] = []; let lock = NSLock() }
        let lines = Lines()
        let listing = try await runner.run(Command(executable: "/bin/ls", arguments: ["/"])) { line in lines.lock.withLock { lines.values.append(line) } }
        #expect(listing.succeeded)
        #expect(lines.values.contains("Applications"))
    }

    /// A busy Mac (GCD's global queues blocked, many commands with blocking output readers) must not
    /// delay a timeout: the command is stopped after 0.3 s, not when it ends on its own 3 s later.
    @Test func timeoutsFireWhileManyCommandsRun() async throws {
        let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: ["/bin/sleep"]), baseEnvironment: [:])
        for _ in 0..<256 { DispatchQueue.global().async { usleep(6_000_000) } }
        let timedOut = try await withThrowingTaskGroup(of: Bool?.self) { group in
            for _ in 0..<20 {
                group.addTask { _ = try await runner.run(Command(executable: "/bin/sleep", arguments: ["1"], timeout: 30)); return nil }
            }
            group.addTask { try await runner.run(Command(executable: "/bin/sleep", arguments: ["3"], timeout: 0.3)).timedOut }
            var result: Bool?
            for try await value in group where value != nil { result = value }
            return result
        }
        #expect(timedOut == true)
    }

    @Test func pathSafetyRejectsTraversal() {
        for good in ["a.otf", "Family/Bold.otf", "Displays/Color LCD.icc", "ünïcode/ß.ttf"] {
            #expect(PathSafety.isSafeRelativePath(good))
        }
        for bad in ["", "/etc/passwd", "../x", "a/../../b", "./a", "a//b", "a/", "~/x", "a\nb", "a\u{0}b", String(repeating: "a", count: 2000)] {
            #expect(!PathSafety.isSafeRelativePath(bad), "\(bad.debugDescription) must be rejected")
        }
        let base = URL(fileURLWithPath: "/tmp/base")
        #expect(PathSafety.resolve("a/b", inside: base)?.path == "/tmp/base/a/b")
        #expect(PathSafety.resolve("../b", inside: base) == nil)
    }

    @Test func restoreNeverWritesOutsideTheTargetFolders() async throws {
        let sandbox = try Sandbox("security-restore")
        let (_, target) = try TestEnvironment.freshMac(sandbox)
        let backup = try sandbox.folder("evil-backup")
        let payload = try sandbox.write("evil", to: "evil-backup/fonts/user/x.otf")
        let record = FileRecord(fileName: "x.otf", domain: .user, relativePath: "../../../escaped.otf", originalPath: "~/x",
                                backupPath: "fonts/user/x.otf", sha256: try Hashing.sha256Hex(ofFile: payload), size: 4)
        let manifest = Manifest(macreplicaVersion: "1", createdAt: Date(), macosVersion: "15", architecture: .arm64, fonts: [record])
        try ManifestIO.write(manifest, to: backup)
        let plan = RestorePlanner().plan(manifest: manifest, selection: RestoreSelection())
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
        let session = await executor.run(plan: plan, session: RestoreSession(backupPath: "x", selection: RestoreSelection(), itemIDs: plan.items.map(\.id)),
                                         onEvent: { _ in })
        #expect(session.results.values.first?.outcome == .failed(RestoreFailure(category: .backupFileDamaged, technicalDetail: "fonts/user/x.otf")))
        #expect(!FileManager.default.fileExists(atPath: target.layout.homeDirectory.deletingLastPathComponent().appendingPathComponent("escaped.otf").path))
    }

    @Test func htmlEscapingAndLinks() {
        #expect(HTML.escape("<script>alert('x')</script> & \"q\"") == "&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &quot;q&quot;")
        #expect(HTML.link("javascript:alert(1)") == "javascript:alert(1)")
        #expect(HTML.link("file:///etc/passwd", label: "x") == "x")
        #expect(HTML.link(nil) == "—")
        #expect(HTML.link("https://example.com/?a=1&b=\"2\"") ==
                "<a href=\"https://example.com/?a=1&amp;b=&quot;2&quot;\" rel=\"noopener noreferrer\">https://example.com/?a=1&amp;b=&quot;2&quot;</a>")
    }

    @Test func reportsEscapeMaliciousNames() {
        var manifest = ManifestTests.sample()
        manifest.applications[0].name = "<img src=x onerror=alert(1)>"
        manifest.applications[2].homepage = "javascript:alert(1)"
        manifest.applications[2].restoreMethod = .officialDownload(url: "javascript:alert(2)")
        let builder = ReportBuilder(localizer: TestEnvironment.english)
        for html in [builder.inventoryReport(manifest), builder.manualInstallationsReport(manifest)] {
            #expect(!html.contains("<img src=x"))
            #expect(!html.contains("href=\"javascript:"))
        }
    }

    @Test func privilegedOperationsUseFixedToolsAndArgumentLists() throws {
        let source = URL(fileURLWithPath: "/tmp/backup/fonts/user/My Font'; rm -rf ~.otf")
        let destination = URL(fileURLWithPath: "/Library/Fonts/My Font'; rm -rf ~.otf")
        let arguments = try AppleScriptPrivilegedExecutor.arguments(
            for: [.createFolder(URL(fileURLWithPath: "/Library/Fonts/Sub")), .installFile(source: source, destination: destination),
                  .installPackage(URL(fileURLWithPath: "/tmp/x/Homebrew.pkg"))], reason: "Reason")
        #expect(arguments[0] == "-e")
        #expect(arguments[1] == AppleScriptPrivilegedExecutor.script)
        #expect(arguments[2] == "Reason")
        // Each path is a separate argument; the script quotes every word with `quoted form of`.
        #expect(arguments.contains(source.path))
        #expect(arguments.contains(destination.path))
        #expect(Array(arguments[3...7]) == ["3", "/bin/mkdir", "-p", "/Library/Fonts/Sub", "9"])
        #expect(arguments.contains("/usr/sbin/installer"))
        #expect(AppleScriptPrivilegedExecutor.script.contains("quoted form of"))
        #expect(!AppleScriptPrivilegedExecutor.script.contains("& item"), "words are never concatenated unquoted")
        #expect(throws: PrivilegedError.invalidPath("/Library/Fonts/a\nb")) {
            _ = try AppleScriptPrivilegedExecutor.arguments(for: [.createFolder(URL(fileURLWithPath: "/Library/Fonts/a\nb"))], reason: "")
        }
        #expect(throws: PrivilegedError.self) {
            _ = try AppleScriptPrivilegedExecutor.arguments(for: [.move(source: URL(fileURLWithPath: "/a/../etc"), destination: URL(fileURLWithPath: "/b"))], reason: "")
        }
    }

    @Test func privilegedExecutorReportsCancellation() async throws {
        let denied = ScriptedRunner { _ in CommandResult(exitCode: 1, stdout: "", stderr: "execution error: User canceled. (-128)") }
        await #expect(throws: PrivilegedError.denied) {
            try await AppleScriptPrivilegedExecutor(runner: denied).run([.createFolder(URL(fileURLWithPath: "/Library/Fonts/X"))], reason: "r")
        }
        let failing = ScriptedRunner { _ in CommandResult(exitCode: 1, stdout: "", stderr: "boom") }
        await #expect(throws: PrivilegedError.failed("boom")) {
            try await AppleScriptPrivilegedExecutor(runner: failing).run([.createFolder(URL(fileURLWithPath: "/Library/Fonts/X"))], reason: "r")
        }
        let none = ScriptedRunner { _ in CommandResult(exitCode: 0, stdout: "", stderr: "") }
        try await AppleScriptPrivilegedExecutor(runner: none).run([], reason: "r")
        #expect(none.commands.isEmpty, "no password prompt without work")
    }

    @Test func homeDirectoryIsRedactedEverywhere() {
        #expect(SystemLayout.redactHome("/Users/jane/Library/Fonts/a.otf", home: "/Users/jane") == "~/Library/Fonts/a.otf")
        #expect(SystemLayout.redactHome("/Users/jane", home: "/Users/jane/") == "~")
        #expect(SystemLayout.redactHome("/Users/janet/x", home: "/Users/jane") == "/Users/janet/x")
        #expect(SystemLayout.redactHome("/x", home: "") == "/x")
        let log = LogStore(fileURL: nil, homeDirectory: URL(fileURLWithPath: "/Users/jane"))
        log.info("copied /Users/jane/Library/Fonts/a.otf and /Users/jane/b")
        #expect(log.allLines.last?.contains("copied ~/Library/Fonts/a.otf and ~/b") == true)
        #expect(log.allLines.last?.contains("jane") == false)
        var layout = SystemLayout.live()
        layout.homeDirectory = URL(fileURLWithPath: "/Users/jane")
        #expect(layout.redact("Error at /Users/jane/x") == "Error at ~/x")
        #expect(layout.resolve(displayPath: "~/Library") == URL(fileURLWithPath: "/Users/jane/Library"))
        #expect(layout.resolve(displayPath: "~") == URL(fileURLWithPath: "/Users/jane"))
        #expect(layout.resolve(displayPath: "/Applications/X.app") == URL(fileURLWithPath: "/Applications/X.app"))
    }

    @Test func manifestNeverContainsTheHomePathOrHostIdentifiers() async throws {
        let sandbox = try Sandbox("security-privacy")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        let manifest = try await TestEnvironment.inventory(source).run().manifest
        let json = String(decoding: try ManifestIO.encode(manifest), as: UTF8.self)
        #expect(!json.contains(source.layout.homeDirectory.path))
        #expect(!json.contains(try #require(source.layout.simulationRoot).path), "no sandbox or account paths at all")
        #expect(!json.contains(NSUserName()))
        #expect(!json.contains(ProcessInfo.processInfo.hostName))
        #expect(!json.lowercased().contains("serial"))
    }

    @Test func childProcessEnvironmentIsExplicit() {
        var layout = SystemLayout.live()
        layout.homeDirectory = URL(fileURLWithPath: "/Users/jane")
        let environment = layout.processEnvironment(homebrewPrefix: URL(fileURLWithPath: "/opt/homebrew"), askpass: "/x/askpass")
        #expect(environment["PATH"] == "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(environment["SUDO_ASKPASS"] == "/x/askpass")
        #expect(environment["NONINTERACTIVE"] == "1")
        #expect(layout.processEnvironment(homebrewPrefix: nil, askpass: nil)["SUDO_ASKPASS"] == nil)
        #expect(layout.processEnvironment(homebrewPrefix: nil, askpass: nil)["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func simulationRootCannotPointOutside() throws {
        let sandbox = try Sandbox("security-sim")
        let root = try SimulationBuilder.create(at: sandbox.url.appendingPathComponent("sim"), scenario: .freshMac)
        let configURL = root.url.appendingPathComponent(SimulationEnvironment.configFileName)
        var config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as! [String: Any]
        config["xcode_select"] = "../../bin/sh"
        try JSONSerialization.data(withJSONObject: config).write(to: configURL)
        #expect(throws: SimulationEnvironment.LoadError.pathOutsideRoot("../../bin/sh")) { _ = try SimulationEnvironment(root: root.url) }
        #expect(SimulationEnvironment.fromLaunchArguments(["app"]) == nil)
        #expect(SimulationEnvironment.fromLaunchArguments(["app", "--simulation-root"]) == nil)
        #expect(throws: SimulationEnvironment.LoadError.missingConfig) { _ = try SimulationEnvironment(root: sandbox.url) }
    }
}
