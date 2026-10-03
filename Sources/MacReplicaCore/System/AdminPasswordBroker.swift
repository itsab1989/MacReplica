import Darwin
import Security
import Foundation

/// Why MacReplica asks for the administrator password.
public enum AdminPasswordPrompt: Sendable, Equatable {
    /// The first request in this restore.
    case first
    /// The password entered before was not accepted by macOS.
    case wrongPassword
}

/// Checks an administrator password without running anything as root.
public protocol AdminPasswordValidating: Sendable {
    func isValid(_ password: String) async -> Bool
}

/// `sudo -S -k -v`: reads the password from standard input, ignores any cached authentication and only
/// validates it. The password never appears in arguments, the environment or logs. This is the only
/// place MacReplica starts `sudo`; the command runner refuses it on purpose.
public struct SudoPasswordValidator: AdminPasswordValidating {
    public var sudo: String

    public init(sudo: String = "/usr/bin/sudo") { self.sudo = sudo }

    public func isValid(_ password: String) async -> Bool {
        guard !password.isEmpty, !password.contains("\n") else { return false }
        let sudo = self.sudo
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: sudo)
                process.arguments = ["-S", "-k", "-v", "-p", ""]
                process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
                let input = Pipe()
                process.standardInput = input
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    try input.fileHandleForWriting.write(contentsOf: Data((password + "\n").utf8))
                    try input.fileHandleForWriting.close()
                } catch {
                    continuation.resume(returning: false)
                    return
                }
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0)
            }
        }
    }
}

/// Hands the administrator password to every `sudo` call of one restore, so Homebrew does not show a
/// dialog per package.
///
/// Without a terminal, `sudo` remembers a successful authentication only per parent process, and every
/// `brew install` is a new process: each cask with an installer package would ask again, and a rejected
/// password made `sudo` silently ask up to three times. The broker asks once, checks the password right
/// away (explaining a wrong one), keeps it in memory until the restore ends and never stores or logs it.
/// After the user cancels, it does not ask again in this restore.
public actor AdminPasswordBroker {
    public typealias Prompt = @Sendable (AdminPasswordPrompt) async -> String?

    private let prompt: Prompt
    private let validator: AdminPasswordValidating
    private let maxAttempts: Int
    private var password: String?
    private var cancelled = false
    /// How often the user was asked (for tests and the log).
    public private(set) var promptCount = 0

    public init(prompt: @escaping Prompt, validator: AdminPasswordValidating = SudoPasswordValidator(), maxAttempts: Int = 3) {
        self.prompt = prompt
        self.validator = validator
        self.maxAttempts = maxAttempts
    }

    /// The validated password, asking the user if needed; nil if the user cancelled or it was not accepted.
    public func validatedPassword() async -> String? {
        if let password { return password }
        if cancelled { return nil }
        var reason = AdminPasswordPrompt.first
        for _ in 0..<maxAttempts {
            promptCount += 1
            guard let entered = await prompt(reason) else {
                cancelled = true
                return nil
            }
            if await validator.isValid(entered) {
                password = entered
                return entered
            }
            reason = .wrongPassword
        }
        cancelled = true
        return nil
    }

    /// Drops the password (end of the restore).
    public func forget() {
        password = nil
    }
}

/// The local channel between MacReplica and its askpass helper during a restore.
///
/// A Unix domain socket in a private folder (permissions 0700) that only answers requests carrying the
/// random token MacReplica passes to Homebrew's environment for this restore. Answers: `OK\t<password>`,
/// `CANCEL` or `DENY`.
public final class AskpassServer: @unchecked Sendable {
    public static let socketVariable = "MACREPLICA_ASKPASS_SOCKET"
    public static let tokenVariable = "MACREPLICA_ASKPASS_TOKEN"

    public let socketPath: String
    public let token: String
    private let folder: URL
    private let broker: AdminPasswordBroker
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var stopped = false

    public init(broker: AdminPasswordBroker) throws {
        self.broker = broker
        var template = Array((NSTemporaryDirectory() + "mr-askpass.XXXXXX").utf8CString)
        guard let created = mkdtemp(&template) else { throw CocoaError(.fileWriteUnknown) }
        folder = URL(fileURLWithPath: String(cString: created))
        chmod(folder.path, 0o700)
        socketPath = folder.appendingPathComponent("s").path
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        try listen()
    }

    public var environment: [String: String] { [Self.socketVariable: socketPath, Self.tokenVariable: token] }

    private func listen() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw CocoaError(.fileWriteInvalidFileName) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path)
            raw[path.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, Darwin.listen(fd, 8) == 0 else { close(fd); throw CocoaError(.fileWriteUnknown) }
        listener = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "MacReplica askpass"
        thread.start()
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if lock.withLock({ stopped }) { return }
                continue
            }
            let thread = Thread { [weak self] in
                guard let self else { close(client); return }
                self.answer(client)
            }
            thread.start()
        }
    }

    private func answer(_ client: Int32) {
        defer { close(client) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = read(client, &buffer, buffer.count)
        guard count > 0 else { return }
        let received = String(decoding: buffer[0..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.constantTimeEqual(received, token) else {
            write(client, "DENY\n")
            return
        }
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var value: String? }
        let box = Box()
        let broker = self.broker
        Task.detached {
            box.value = await broker.validatedPassword()
            semaphore.signal()
        }
        semaphore.wait()
        if let password = box.value {
            write(client, "OK\t" + password + "\n")
        } else {
            write(client, "CANCEL\n")
        }
    }

    private func write(_ client: Int32, _ text: String) {
        let data = Array(text.utf8)
        _ = data.withUnsafeBytes { Darwin.write(client, $0.baseAddress, $0.count) }
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Closes the socket and removes its folder. Requests after this are not answered.
    public func stop() {
        let fd: Int32 = lock.withLock {
            stopped = true
            defer { listener = -1 }
            return listener
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        try? FileManager.default.removeItem(at: folder)
    }

    deinit { stop() }
}
