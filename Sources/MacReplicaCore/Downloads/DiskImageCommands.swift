import Foundation

/// Runs `hdiutil` commands one at a time. macOS's disk-image service answers concurrent attach and detach
/// requests with "Resource temporarily unavailable" and can then leave an image attached; MacReplica never needs
/// two at once, so they are queued.
public enum DiskImageCommands {
    private actor Queue {
        private var busy = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !busy {
                busy = true
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            if waiting.isEmpty {
                busy = false
            } else {
                waiting.removeFirst().resume()
            }
        }
    }

    private static let queue = Queue()

    public static func run(_ runner: CommandRunning, _ command: Command) async throws -> CommandResult {
        await queue.acquire()
        do {
            let result = try await runner.run(command)
            await queue.release()
            return result
        } catch {
            await queue.release()
            throw error
        }
    }
}
