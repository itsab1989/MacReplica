import Foundation

/// The result of running an external tool.
public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 && !timedOut }
    public var combinedOutput: String { stdout + (stderr.isEmpty ? "" : "\n" + stderr) }
}

/// A request to run one external tool.
///
/// There is deliberately no way to pass a shell command line: the executable is
/// an absolute path and every argument is handed to the process verbatim, so
/// names coming from a backup can never be interpreted by a shell.
public struct Command: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var timeout: TimeInterval

    public init(executable: String, arguments: [String] = [], environment: [String: String] = [:], timeout: TimeInterval = 120) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.timeout = timeout
    }
}

public enum CommandError: Error, Equatable, Sendable {
    case notAllowed(String)
    case notExecutable(String)
    case invalidArgument(String)
    case launchFailed(String)
}

public protocol CommandRunning: Sendable {
    /// Runs the command and returns its output. `onOutputLine` receives output lines as they arrive.
    func run(_ command: Command, onOutputLine: (@Sendable (String) -> Void)?) async throws -> CommandResult
}

extension CommandRunning {
    public func run(_ command: Command) async throws -> CommandResult {
        try await run(command, onOutputLine: nil)
    }
}

/// Validates commands before they are executed.
public struct CommandPolicy: Sendable {
    /// Absolute paths of the only executables MacReplica may start.
    public var allowedExecutables: Set<String>

    /// Programs that are never allowed, whatever folder they are in: shells and interpreters that
    /// would run a command line, and tools that escalate privileges.
    public static let forbiddenNames: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish", "env", "sudo", "su",
                                                    "doas", "eval", "xargs", "perl", "ruby", "node", "osascript", "launchctl"]

    public init(allowedExecutables: Set<String>) {
        self.allowedExecutables = allowedExecutables
    }

    /// The policy plus exact additional executables (absolute paths). Shells and the like are dropped.
    public func adding(_ executables: Set<String>) -> CommandPolicy {
        let accepted = executables.filter { path in
            path.hasPrefix("/") && !path.contains("/../") && !path.hasSuffix("/..")
                && !Self.forbiddenNames.contains((path as NSString).lastPathComponent.lowercased())
        }
        return CommandPolicy(allowedExecutables: allowedExecutables.union(accepted))
    }

    public func validate(_ command: Command) throws {
        let path = command.executable
        guard path.hasPrefix("/"), !path.contains("/../"), !path.hasSuffix("/..") else {
            throw CommandError.notAllowed(path)
        }
        guard allowedExecutables.contains(path) else {
            throw CommandError.notAllowed(path)
        }
        for argument in command.arguments where argument.contains("\0") {
            throw CommandError.invalidArgument(argument)
        }
        for (key, value) in command.environment where key.contains("=") || key.contains("\0") || value.contains("\0") {
            throw CommandError.invalidArgument(key)
        }
    }
}

/// A runner whose allow-list can be extended by exact executables for one restore.
public protocol CommandPolicyExtending: CommandRunning {
    func allowing(_ executables: Set<String>) -> CommandRunning
}

/// Runs allow-listed executables with `Process`, never through a shell.
public final class ProcessCommandRunner: CommandRunning, CommandPolicyExtending, @unchecked Sendable {
    private let policy: CommandPolicy
    private let baseEnvironment: [String: String]

    /// - Parameter baseEnvironment: The complete environment for child processes.
    ///   MacReplica does not inherit the caller's `PATH`; it is set explicitly.
    public init(policy: CommandPolicy, baseEnvironment: [String: String]) {
        self.policy = policy
        self.baseEnvironment = baseEnvironment
    }

    /// Timeouts run on their own serial queue so that busy global queues cannot delay them.
    private static let timeoutQueue = DispatchQueue(label: "MacReplica.command-timeouts", qos: .userInitiated)
    /// Results are delivered from a queue of their own for the same reason.
    private static let completionQueue = DispatchQueue(label: "MacReplica.command-results", qos: .userInitiated, attributes: .concurrent)

    public func allowing(_ executables: Set<String>) -> CommandRunning {
        ProcessCommandRunner(policy: policy.adding(executables), baseEnvironment: baseEnvironment)
    }

    public func run(_ command: Command, onOutputLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
        try policy.validate(command)
        guard FileManager.default.isExecutableFile(atPath: command.executable) else {
            throw CommandError.notExecutable(command.executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = baseEnvironment.merging(command.environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let collector = OutputCollector(onLine: onOutputLine)
        // Each pipe is drained on its own thread until end-of-file; the result is only
        // assembled after both readers finished, so no output can be lost. The reads block,
        // so they get dedicated threads: on GCD's global queues, many running commands could
        // occupy all worker threads and delay everything else, including timeouts.
        let readers = DispatchGroup()
        for (pipe, isError) in [(stdoutPipe, false), (stderrPipe, true)] {
            readers.enter()
            let reader = Thread {
                // read(2) returns what has arrived so far, so lines reach `onOutputLine` while the tool runs
                // (FileHandle.read(upToCount:) waits until the whole count or the end of the output).
                let descriptor = pipe.fileHandleForReading.fileDescriptor
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                    if count > 0 { collector.append(Data(buffer[0..<count]), isError: isError); continue }
                    if count < 0 && errno == EINTR { continue }
                    break
                }
                readers.leave()
            }
            reader.name = "MacReplica command output"
            reader.qualityOfService = .utility
            reader.start()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                let timeoutState = TimeoutState()
                process.terminationHandler = { finished in
                    readers.notify(queue: Self.completionQueue) {
                        let output = collector.finish()
                        continuation.resume(returning: CommandResult(
                            exitCode: finished.terminationStatus,
                            stdout: output.stdout,
                            stderr: output.stderr,
                            timedOut: timeoutState.fired
                        ))
                    }
                }
                do {
                    try process.run()
                    // The child holds the write ends now; close ours so the readers see end-of-file.
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                } catch {
                    try? stdoutPipe.fileHandleForWriting.close()
                    try? stderrPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: CommandError.launchFailed(error.localizedDescription))
                    return
                }
                if command.timeout > 0 {
                    Self.timeoutQueue.asyncAfter(deadline: .now() + command.timeout) {
                        if process.isRunning {
                            timeoutState.fired = true
                            process.terminate()
                        }
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var _fired = false
    var fired: Bool {
        get { lock.withLock { _fired } }
        set { lock.withLock { _fired = newValue } }
    }
}

/// Thread-safe accumulator for process output that also emits complete lines.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var pendingLine = Data()
    private var endedWithCarriageReturn = false
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ data: Data, isError: Bool) {
        guard !data.isEmpty else { return }
        var lines: [String] = []
        lock.withLock {
            if isError { stderr.append(data) } else { stdout.append(data) }
            guard onLine != nil else { return }
            pendingLine.append(data)
            // Progress is often redrawn with a carriage return (`softwareupdate`: "Installing: 6.0%\r"), so a
            // carriage return ends a line too; "\r\n" ends just one.
            while let end = pendingLine.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let lineData = pendingLine[pendingLine.startIndex..<end]
                let isLineFeed = pendingLine[end] == 0x0A
                if !(isLineFeed && lineData.isEmpty && endedWithCarriageReturn) {
                    lines.append(String(decoding: lineData, as: UTF8.self))
                }
                endedWithCarriageReturn = !isLineFeed
                pendingLine.removeSubrange(pendingLine.startIndex...end)
            }
        }
        for line in lines { onLine?(line) }
    }

    func finish() -> (stdout: String, stderr: String) {
        lock.withLock {
            if let onLine, !pendingLine.isEmpty {
                onLine(String(decoding: pendingLine, as: UTF8.self))
                pendingLine.removeAll()
            }
            return (String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
        }
    }
}
