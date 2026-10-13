import Foundation

/// The copy of MacReplica itself that a backup carries, so the restore can start on a freshly installed Mac without
/// a download: open the backup, move `MacReplica.app` to Applications, open it.
public struct BootstrapAppRecord: Codable, Equatable, Sendable {
    /// Inside the backup folder: `MacReplica.app`.
    public var path: String
    public var version: String
    public var build: String?
    /// The processors the copy runs on. A release build runs on both.
    public var architectures: [CPUArchitecture]
    /// Developer team of the signature; nil for an ad-hoc signed build (not notarized by Apple).
    public var teamIdentifier: String?

    public init(path: String, version: String, build: String?, architectures: [CPUArchitecture], teamIdentifier: String?) {
        self.path = path
        self.version = version
        self.build = build
        self.architectures = architectures
        self.teamIdentifier = teamIdentifier
    }

    public var isUniversal: Bool { Set(architectures).isSuperset(of: [.arm64, .x86_64]) }

    /// The copy runs on a Mac with this processor.
    public func runs(on architecture: CPUArchitecture) -> Bool {
        architectures.contains(architecture) || (architecture == .arm64 && architectures.contains(.x86_64))
    }
}

public enum BootstrapAppError: Error, Equatable, Sendable {
    /// The running app's signature is broken (e.g. a damaged installation); a copy is not put into the backup.
    case signatureInvalid
    case copyFailed(String)
}

public enum BootstrapApp {
    public static let bundleName = "MacReplica.app"

    /// Copies the running MacReplica into the backup, keeping the code signature and the file attributes as they are
    /// (including a quarantine flag: macOS checks the copy on the new Mac like any other app – nothing is removed).
    /// The copy is checked: intact signature, same version. Returns nil when MacReplica does not run from an app bundle.
    public static func copy(_ bundle: URL, into root: URL) throws -> BootstrapAppRecord? {
        guard bundle.pathExtension == "app",
              let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String else { return nil }
        guard BundleInspection.hasValidSignature(bundle, teamIdentifier: nil) else { throw BootstrapAppError.signatureInvalid }
        let destination = root.appendingPathComponent(bundleName)
        do {
            try FileManager.default.copyItem(at: bundle, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw BootstrapAppError.copyFailed(String(describing: error))
        }
        let copied = NSDictionary(contentsOf: destination.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        guard copied?["CFBundleShortVersionString"] as? String == version, BundleInspection.hasValidSignature(destination, teamIdentifier: nil) else {
            try? FileManager.default.removeItem(at: destination)
            throw BootstrapAppError.copyFailed("the copy does not match")
        }
        var architectures: [CPUArchitecture] = []
        if let executable = info["CFBundleExecutable"] as? String, !executable.contains("/") {
            architectures = MachO.architectures(ofFile: destination.appendingPathComponent("Contents/MacOS/\(executable)"))
        }
        return BootstrapAppRecord(path: bundleName, version: version, build: info["CFBundleVersion"] as? String, architectures: architectures,
                                  teamIdentifier: BundleInspection.signingIdentity(of: destination)?.teamIdentifier)
    }

    /// Size of the bundle, for the space estimate.
    public static func size(of bundle: URL) -> Int64 {
        guard bundle.pathExtension == "app", let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}
