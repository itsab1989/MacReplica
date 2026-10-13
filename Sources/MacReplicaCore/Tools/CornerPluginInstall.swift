import Foundation

/// The one-click helper that sets up the Ammonia tweak loader for the corner plugin. The user still turns off System
/// Integrity Protection in recoveryOS themselves (MacReplica never changes SIP); everything after that MacReplica can
/// do for them, with a warning, the administrator password and a full undo.
///
/// MacReplica's only privileged action to install is `installer -pkg` on a pinned, checksum-verified download of
/// Ammonia, plus copying its own plugin. Ammonia's own installer sets the boot argument and disables library
/// validation (its postinstall). Undo removes the plugin, uninstalls Ammonia the way its own uninstaller does, and –
/// only when nothing else depends on them – clears the boot argument and re-enables library validation. SIP is the
/// user's step again at the end.
public enum AmmoniaInstaller {
    /// A pinned Ammonia release. Downloaded over HTTPS, then checked against this exact SHA-256 before it is installed;
    /// a mismatch stops the install. The `.pkg` is unsigned (it is a tweak loader), so the checksum is the only trust.
    public struct Release: Sendable, Equatable {
        public var version: String
        public var url: URL
        public var sha256: String
        public var size: Int64
        public init(version: String, url: URL, sha256: String, size: Int64) {
            self.version = version
            self.url = url
            self.sha256 = sha256
            self.size = size
        }
    }

    /// Verified on 2026-10-14 (downloaded from the GitHub release and hashed locally; see docs/TOOLS.md).
    public static let release = Release(
        version: "1.5",
        url: URL(string: "https://github.com/CoreBedtime/ammonia/releases/download/1.5/ammonia.pkg")!,
        sha256: "845d4482b2f474433267cefd97a13f1532113541837012da8481a4f198ff6884",
        size: 14_110_824)

    public static let receiptIdentifier = "net.bedtime.ammonia"
    public static let daemonLabel = "com.bedtime.ammonia"
    public static let daemonPlist = URL(fileURLWithPath: "/Library/LaunchDaemons/com.bedtime.ammonia.plist")
    public static let installRoot = URL(fileURLWithPath: "/private/var/ammonia")
    public static let bootArgument = "-arm64e_preview_abi"
    public static let libraryValidationPlist = "/Library/Preferences/com.apple.security.libraryvalidation.plist"

    public enum InstallError: Error, Equatable {
        case downloadFailed(String)
        case checksumMismatch(expected: String, got: String)
    }

    /// Downloads the pinned Ammonia package into `work` and verifies its SHA-256. Returns the local file, ready to be
    /// installed with `PrivilegedOperation.installPackage`. Never installs anything by itself.
    public static func downloadVerifiedPackage(_ release: Release = release, transport: DownloadTransport, work: URL,
                                               progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws -> URL {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let destination = work.appendingPathComponent("ammonia-\(release.version).pkg")
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        let file: URL
        do {
            file = try await transport.download(from: release.url, resumeData: nil, to: destination, progress: progress)
        } catch {
            throw InstallError.downloadFailed(String(describing: error))
        }
        let hash = try Hashing.sha256Hex(ofFile: file)
        guard hash.caseInsensitiveCompare(release.sha256) == .orderedSame else {
            try? FileManager.default.removeItem(at: file)
            throw InstallError.checksumMismatch(expected: release.sha256, got: hash)
        }
        return file
    }

    /// The privileged steps that uninstall Ammonia: remove its launch daemon and its folder. Each is tolerant of the
    /// target already being gone (`rm -rf`). The daemon stops for good at the next restart, which the user does anyway
    /// to clear the boot argument and re-enable System Integrity Protection. The boot argument and library validation
    /// are handled separately (see `bootArgumentCleanup`) so they are only touched when safe.
    public static func uninstallOperations() -> [PrivilegedOperation] {
        [.removeSystemItem(daemonPlist), .removeSystemItem(installRoot)]
    }

    /// Whether the current `boot-args` can be cleared without losing settings the user cares about: it holds only the
    /// Ammonia boot argument (possibly repeated, as Ammonia's installer writes it). `nil` boot-args means none are set.
    public static func bootArgumentsAreOnlyOurs(_ bootArgs: String?) -> Bool {
        guard let bootArgs, !bootArgs.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let tokens = bootArgs.split(whereSeparator: \.isWhitespace)
        return !tokens.isEmpty && tokens.allSatisfy { $0 == bootArgument }
    }

    /// The boot argument from `nvram boot-args` output (`boot-args\t-arm64e_preview_abi …`), or nil if none is set.
    public static func bootArgumentsValue(nvramOutput: String?) -> String? {
        // `nvram boot-args` prints `boot-args\t<value>` on one line; its error message also contains the word
        // "boot-args", so only a line that begins with it is read.
        guard let output = nvramOutput else { return nil }
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("boot-args") {
            let value = line.dropFirst("boot-args".count).drop { $0 == "\t" || $0 == " " }
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }

    /// The extra privileged steps that fully reverse Ammonia's side effects, added to `uninstallOperations()` only
    /// when `bootArgumentsAreOnlyOurs` is true. Otherwise MacReplica shows the commands and the user decides.
    public static func bootArgumentCleanup() -> [PrivilegedOperation] {
        [.clearBootArguments, .enableLibraryValidation]
    }
}
