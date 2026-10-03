import Foundation

/// Moves bytes from a URL to a file. Cancelling the calling task pauses the download: the transport
/// throws `DownloadInterruption` with whatever it needs to continue later.
public protocol DownloadTransport: Sendable {
    func download(from url: URL, resumeData: Data?, to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL
}

/// Thrown by a transport when the download was stopped; `resumeData` continues it if the server allows.
public struct DownloadInterruption: Error, Sendable {
    public var resumeData: Data?
    public init(resumeData: Data?) { self.resumeData = resumeData }
}

public enum DownloadState: Equatable, Sendable {
    case queued
    case downloading(received: Int64, expected: Int64?)
    case paused
    case finished(URL)
    case failed(DownloadError)
    case cancelled

    public var isActive: Bool {
        switch self {
        case .queued, .downloading: return true
        default: return false
        }
    }
}

/// Downloads chosen offers one or two at a time with pause, resume, retry and cancel. Every step is logged.
public actor DownloadQueue {
    public typealias Observer = @Sendable (String, DownloadState) -> Void

    private let transport: DownloadTransport
    private let folder: URL
    private let maxConcurrent: Int
    private let log: LogStore?
    private let observer: Observer

    private var offers: [String: DownloadOffer] = [:]
    private var order: [String] = []
    private var states: [String: DownloadState] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var resumeData: [String: Data] = [:]
    private var pausing = Set<String>()

    /// - Parameter folder: MacReplica's own download folder; files are named after the offer, never after the server.
    public init(transport: DownloadTransport, folder: URL, maxConcurrent: Int = 2, log: LogStore? = nil, observer: @escaping Observer = { _, _ in }) {
        self.transport = transport
        self.folder = folder
        self.maxConcurrent = max(1, maxConcurrent)
        self.log = log
        self.observer = observer
    }

    public func state(_ id: String) -> DownloadState? { states[id] }
    public func allStates() -> [String: DownloadState] { states }

    /// Adds an offer (keyed by its restore item). Offers MacReplica cannot verify are refused.
    public func enqueue(_ offer: DownloadOffer) {
        guard offer.isDownloadable, let url = URL(string: offer.url), url.scheme == "https" || (url.scheme == "http" && offer.edSignature != nil) else {
            set(offer.itemID, .failed(.insecureURL(offer.url)))
            return
        }
        offers[offer.itemID] = offer
        if !order.contains(offer.itemID) { order.append(offer.itemID) }
        resumeData[offer.itemID] = nil
        set(offer.itemID, .queued)
        log?.info("Download queued: \(offer.itemID) from \(offer.host)", component: .downloads)
        startNext()
    }

    public func pause(_ id: String) {
        guard let task = tasks[id], case .downloading = states[id] else {
            if states[id] == .queued { set(id, .paused) }
            return
        }
        pausing.insert(id)
        task.cancel()
    }

    public func resume(_ id: String) {
        guard states[id] == .paused else { return }
        set(id, .queued)
        log?.info("Download resumed: \(id)", component: .downloads)
        startNext()
    }

    public func retry(_ id: String) {
        guard let state = states[id], !state.isActive, offers[id] != nil else { return }
        resumeData[id] = nil
        set(id, .queued)
        log?.info("Download retried: \(id)", component: .downloads)
        startNext()
    }

    public func cancel(_ id: String) {
        pausing.remove(id)
        tasks[id]?.cancel()
        tasks[id] = nil
        resumeData[id] = nil
        set(id, .cancelled)
        log?.info("Download cancelled by the user: \(id)", component: .downloads)
        startNext()
    }

    /// Waits until no download is queued or running.
    public func waitUntilIdle() async {
        while states.values.contains(where: \.isActive) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func set(_ id: String, _ state: DownloadState) {
        states[id] = state
        observer(id, state)
    }

    private func startNext() {
        let running = tasks.count
        guard running < maxConcurrent else { return }
        for id in order where states[id] == .queued && tasks[id] == nil {
            guard tasks.count < maxConcurrent, let offer = offers[id] else { break }
            start(offer)
        }
    }

    private func start(_ offer: DownloadOffer) {
        let id = offer.itemID
        let destination = folder.appendingPathComponent(Self.fileName(for: offer))
        let resume = resumeData[id]
        set(id, .downloading(received: 0, expected: offer.expectedLength))
        let transport = self.transport
        let folder = self.folder
        tasks[id] = Task { [weak self] in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                guard let url = URL(string: offer.url) else { throw DownloadError.insecureURL(offer.url) }
                let queue = self
                let file = try await transport.download(from: url, resumeData: resume, to: destination) { received, expected in
                    Task { await queue?.progress(id, received, expected ?? offer.expectedLength) }
                }
                await self?.finish(id, .finished(file))
            } catch let interruption as DownloadInterruption {
                await self?.interrupted(id, resumeData: interruption.resumeData)
            } catch let error as DownloadError {
                await self?.finish(id, .failed(error))
            } catch is CancellationError {
                await self?.interrupted(id, resumeData: nil)
            } catch {
                await self?.finish(id, .failed(.network(String(describing: error))))
            }
        }
    }

    private func progress(_ id: String, _ received: Int64, _ expected: Int64?) {
        guard case .downloading = states[id] else { return }
        set(id, .downloading(received: received, expected: expected))
    }

    private func interrupted(_ id: String, resumeData data: Data?) {
        tasks[id] = nil
        if pausing.remove(id) != nil {
            resumeData[id] = data
            set(id, .paused)
            log?.info("Download paused: \(id)\(data == nil ? " (will start over)" : "")", component: .downloads)
        } else if states[id] != .cancelled {
            set(id, .failed(.cancelled))
        }
        startNext()
    }

    private func finish(_ id: String, _ state: DownloadState) {
        tasks[id] = nil
        guard states[id] != .cancelled else { return }
        set(id, state)
        switch state {
        case .finished: log?.info("Download finished: \(id)", component: .downloads)
        case .failed(let error): log?.warning("Download failed: \(id): \(error)", component: .downloads)
        default: break
        }
        startNext()
    }

    /// `<item hash>.<extension from the URL path>`; the server never chooses the file name.
    static func fileName(for offer: DownloadOffer) -> String {
        let ext = URL(string: offer.url).map { $0.pathExtension.lowercased() } ?? ""
        let allowed = ["dmg", "zip", "pkg", "tbz", "tgz", "xz", "gz"]
        let hash = Hashing.sha256Hex(of: Data(offer.itemID.utf8)).prefix(16)
        return "download-\(hash)" + (allowed.contains(ext) ? ".\(ext)" : "")
    }
}

// MARK: - Transports

/// The real network: a default URLSession (so every redirect can be checked) with resumable tasks.
public final class URLSessionDownloadTransport: NSObject, DownloadTransport, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Pending {
        var continuation: CheckedContinuation<URL, Error>
        var destination: URL
        var progress: @Sendable (Int64, Int64?) -> Void
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.httpAdditionalHeaders = ["User-Agent": "MacReplica/\(SystemInfo.appVersion)"]
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public override init() { super.init() }

    public func download(from url: URL, resumeData: Data?, to destination: URL,
                         progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { pending[task.taskIdentifier] = Pending(continuation: continuation, destination: destination, progress: progress) }
                task.resume()
            }
        } onCancel: {
            task.cancel(byProducingResumeData: { _ in })
        }
    }

    private func take(_ task: URLSessionTask) -> Pending? {
        lock.withLock { pending.removeValue(forKey: task.taskIdentifier) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Downloads stay on HTTPS when they started there.
        let secure = task.originalRequest?.url?.scheme != "https" || request.url?.scheme == "https"
        completionHandler(secure ? request : nil)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let handler = lock.withLock { pending[downloadTask.taskIdentifier]?.progress }
        handler?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let entry = lock.withLock({ pending[downloadTask.taskIdentifier] }) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            _ = take(downloadTask)
            entry.continuation.resume(throwing: DownloadError.httpStatus(http.statusCode))
            return
        }
        do {
            if FileManager.default.fileExists(atPath: entry.destination.path) { try FileManager.default.removeItem(at: entry.destination) }
            try FileManager.default.moveItem(at: location, to: entry.destination)
            _ = take(downloadTask)
            entry.continuation.resume(returning: entry.destination)
        } catch {
            _ = take(downloadTask)
            entry.continuation.resume(throwing: DownloadError.network(error.localizedDescription))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let entry = take(task) else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled {
            entry.continuation.resume(throwing: DownloadInterruption(resumeData: nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data))
        } else {
            entry.continuation.resume(throwing: DownloadError.network(error.localizedDescription))
        }
    }
}

/// Serves downloads from `<root>/downloads/<host>/<path>` in chunks, with resume support (tests and simulation).
public struct LocalDownloadTransport: DownloadTransport {
    public var root: URL
    public var chunkSize: Int
    public var delayPerChunk: TimeInterval

    public init(root: URL, chunkSize: Int = 64 * 1024, delayPerChunk: TimeInterval = 0) {
        self.root = root
        self.chunkSize = chunkSize
        self.delayPerChunk = delayPerChunk
    }

    public func download(from url: URL, resumeData: Data?, to destination: URL,
                         progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        guard let source = LocalFetcher.file(for: url, root: root), let data = FileManager.default.contents(atPath: source.path) else {
            throw DownloadError.httpStatus(404)
        }
        let partial = destination.appendingPathExtension("part")
        var offset = resumeData.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        if offset == 0 || !FileManager.default.fileExists(atPath: partial.path) {
            offset = 0
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(offset))
        try handle.seekToEnd()
        while offset < data.count {
            if Task.isCancelled { throw DownloadInterruption(resumeData: Data(String(offset).utf8)) }
            let end = min(offset + chunkSize, data.count)
            try handle.write(contentsOf: data[offset..<end])
            offset = end
            progress(Int64(offset), Int64(data.count))
            if delayPerChunk > 0 { try? await Task.sleep(nanoseconds: UInt64(delayPerChunk * 1_000_000_000)) }
        }
        try handle.close()
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: partial, to: destination)
        return destination
    }
}
