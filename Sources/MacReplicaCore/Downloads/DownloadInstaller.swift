import CoreServices
import CryptoKit
import Foundation

/// What a verified download contains and how it gets installed.
public enum PreparedDownload: Equatable, Sendable {
    /// A verified application bundle, ready to be copied into the Applications folder.
    case application(bundle: URL, mountPoint: URL?)
    /// A signed installer package; the user completes it in Installer.
    case package(URL, teamIdentifier: String?)
    /// Opened in Finder for the user, e.g. a disk image with a license agreement that must be accepted there.
    case openInFinder(URL, reason: DownloadError)
}

/// Verifies downloaded files and installs what they contain without administrator rights.
///
/// Nothing from a download is ever executed by MacReplica: applications are copied after their code
/// signature was checked, installer packages are handed to Apple's Installer for the user, and every
/// downloaded file keeps the quarantine flag so that Gatekeeper checks it on first launch.
public struct DownloadInstaller: Sendable {
    public var layout: SystemLayout
    public var runner: CommandRunning
    public var macOSVersion: String
    public var architecture: CPUArchitecture
    public var rosettaInstalled: Bool

    public init(layout: SystemLayout, runner: CommandRunning, macOSVersion: String, architecture: CPUArchitecture, rosettaInstalled: Bool = true) {
        self.layout = layout
        self.runner = runner
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.rosettaInstalled = rosettaInstalled
    }

    /// MacReplica's own download folder (marked as owned, so clean-up never touches anything else).
    public var downloadsFolder: URL { layout.caches.appendingPathComponent("Downloads") }

    // MARK: File checks

    /// Size, checksum and vendor signature of the downloaded file, then the quarantine flag.
    public func verifyFile(_ file: URL, offer: DownloadOffer) throws {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? -1
        guard size > 0 else { throw DownloadError.sizeMismatch(expected: offer.expectedLength ?? 0, actual: max(size, 0)) }
        if let expected = offer.expectedLength, expected > 0, expected != size { throw DownloadError.sizeMismatch(expected: expected, actual: size) }
        if let sha = offer.sha256 {
            guard (try? Hashing.sha256Hex(ofFile: file)) == sha.lowercased() else { throw DownloadError.checksumMismatch }
        }
        if let signature = offer.edSignature, let key = offer.publicEDKey {
            guard Self.isValidEdDSASignature(signature, publicKey: key, file: file) else { throw DownloadError.signatureInvalid }
        }
        if offer.trust == .none { throw DownloadError.signatureInvalid }
        try Self.quarantine(file, source: offer.url)
    }

    /// Sparkle's EdDSA signature covers the raw bytes of the downloaded file.
    public static func isValidEdDSASignature(_ signature: String, publicKey: String, file: URL) -> Bool {
        guard let keyData = Data(base64Encoded: publicKey), keyData.count == 32,
              let signatureData = Data(base64Encoded: signature), signatureData.count == 64,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return false }
        return key.isValidSignature(signatureData, for: data)
    }

    /// Marks a file as downloaded from the internet, as browsers do, so that Gatekeeper assesses it.
    public static func quarantine(_ file: URL, source: String) throws {
        var values = URLResourceValues()
        var properties: [String: Any] = [kLSQuarantineAgentNameKey as String: "MacReplica",
                                         kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String]
        if let url = URL(string: source) { properties[kLSQuarantineDataURLKey as String] = url }
        values.quarantineProperties = properties
        var target = file
        try target.setResourceValues(values)
    }

    // MARK: Unpacking

    /// Unpacks a verified download into a staging folder and checks what it contains.
    public func prepare(_ file: URL, offer: DownloadOffer, staging: URL) async throws -> PreparedDownload {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        switch file.pathExtension.lowercased() {
        case "pkg":
            return try await preparePackage(file, offer: offer)
        case "zip":
            let folder = staging.appendingPathComponent("extracted")
            let result = try await runner.run(Command(executable: layout.ditto, arguments: ["-x", "-k", file.path, folder.path],
                                                      environment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil), timeout: 600))
            guard result.succeeded else { throw DownloadError.extractionFailed(layout.redact(result.combinedOutput)) }
            if let app = Self.findApplication(in: folder) {
                try checkApplication(app, offer: offer)
                return .application(bundle: app, mountPoint: nil)
            }
            if let package = Self.find(extension: "pkg", in: folder) { return try await preparePackage(package, offer: offer) }
            throw DownloadError.noApplicationFound
        case "dmg":
            return try await prepareDiskImage(file, offer: offer, staging: staging)
        default:
            return .openInFinder(file, reason: .noApplicationFound)
        }
    }

    func prepareDiskImage(_ file: URL, offer: DownloadOffer, staging: URL) async throws -> PreparedDownload {
        let environment = layout.processEnvironment(homebrewPrefix: nil, askpass: nil)
        let info = try await runner.run(Command(executable: layout.hdiutil, arguments: ["imageinfo", "-plist", file.path],
                                                environment: environment, timeout: 120))
        guard info.succeeded else { throw DownloadError.extractionFailed("hdiutil imageinfo failed") }
        if Self.hasLicenseAgreement(imageInfo: info.stdout) {
            // The license must be accepted by the user; MacReplica never answers it.
            return .openInFinder(file, reason: .licenseAgreement)
        }
        let mountRoot = staging.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        let attach = try await runner.run(Command(executable: layout.hdiutil,
                                                  arguments: ["attach", "-plist", "-nobrowse", "-readonly", "-noautoopen", "-mountrandom", mountRoot.path, file.path],
                                                  environment: environment, timeout: 300))
        guard attach.succeeded, let mountPoint = Self.mountPoint(fromAttachOutput: attach.stdout) else {
            throw DownloadError.extractionFailed("hdiutil attach failed")
        }
        do {
            if let app = Self.findApplication(in: mountPoint, depth: 1) {
                try checkApplication(app, offer: offer)
                return .application(bundle: app, mountPoint: mountPoint)
            }
            if let package = Self.find(extension: "pkg", in: mountPoint, depth: 1) {
                // The package must stay readable after the image is detached, so it is copied out first.
                let copy = staging.appendingPathComponent(package.lastPathComponent)
                try FileManager.default.copyItem(at: package, to: copy)
                await detach(mountPoint)
                return try await preparePackage(copy, offer: offer)
            }
            throw DownloadError.noApplicationFound
        } catch {
            await detach(mountPoint)
            throw error
        }
    }

    func preparePackage(_ file: URL, offer: DownloadOffer) async throws -> PreparedDownload {
        let result = try await runner.run(Command(executable: layout.pkgutil, arguments: ["--check-signature", file.path],
                                                  environment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil), timeout: 120))
        let (signed, team) = Self.parsePackageSignature(result.stdout)
        guard result.succeeded, signed else { throw DownloadError.untrustedPackage("no trusted signature") }
        if let expected = offer.expectedTeamIdentifier, team != expected { throw DownloadError.wrongDeveloper(expected: expected, actual: team) }
        return .package(file, teamIdentifier: team)
    }

    public func detach(_ mountPoint: URL) async {
        _ = try? await runner.run(Command(executable: layout.hdiutil, arguments: ["detach", mountPoint.path],
                                          environment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil), timeout: 120))
    }

    // MARK: Application checks

    /// The same app as on the old Mac (bundle identifier, developer team, valid signature) that runs on this Mac.
    public func checkApplication(_ bundle: URL, offer: DownloadOffer) throws {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw DownloadError.noApplicationFound
        }
        let identifier = info["CFBundleIdentifier"] as? String
        if let expected = offer.expectedBundleIdentifier, identifier?.lowercased() != expected.lowercased() {
            throw DownloadError.wrongApplication(identifier ?? "")
        }
        if let team = offer.expectedTeamIdentifier {
            let actual = BundleInspection.signingIdentity(of: bundle)?.teamIdentifier
            guard actual == team else { throw DownloadError.wrongDeveloper(expected: team, actual: actual) }
            guard BundleInspection.hasValidSignature(bundle, teamIdentifier: team) else { throw DownloadError.codeSignatureInvalid }
        }
        if let executable = info["CFBundleExecutable"] as? String, !executable.contains("/") {
            let architectures = MachO.architectures(ofFile: bundle.appendingPathComponent("Contents/MacOS/\(executable)"))
            let runsHere = architectures.isEmpty || architectures.contains(architecture)
                || (architecture == .arm64 && architectures.contains(.x86_64) && rosettaInstalled)
            guard runsHere else { throw DownloadError.incompatibleArchitecture }
        }
        if let minimum = info["LSMinimumSystemVersion"] as? String, VersionComparison.compare(macOSVersion, minimum) == .orderedAscending {
            throw DownloadError.requiresNewerMacOS(minimum)
        }
    }

    // MARK: Installing

    /// Copies a verified application into the Applications folder. Existing apps are never replaced,
    /// and nothing needs administrator rights: if the folder is not writable, the user is asked to drag it in Finder.
    public func installApplication(_ bundle: URL, source: String) throws -> URL {
        guard let folder = layout.applicationFolders.first else { throw DownloadError.applicationsFolderNotWritable }
        let destination = folder.appendingPathComponent(bundle.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw DownloadError.alreadyInstalled }
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw DownloadError.applicationsFolderNotWritable }
        try FileManager.default.copyItem(at: bundle, to: destination)
        try Self.quarantine(destination, source: source)
        return destination
    }

    // MARK: Parsing helpers

    static func hasLicenseAgreement(imageInfo plist: String) -> Bool {
        guard let data = plist.data(using: .utf8),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return object["Software License Agreement"] as? Bool ?? false
    }

    static func mountPoint(fromAttachOutput plist: String) -> URL? {
        // hdiutil may print warnings before the plist on newer macOS; parse from the XML declaration on.
        let start = plist.range(of: "<?xml")?.lowerBound ?? plist.startIndex
        guard let data = String(plist[start...]).data(using: .utf8),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = object["system-entities"] as? [[String: Any]] else { return nil }
        return entities.compactMap { $0["mount-point"] as? String }.first.map { URL(fileURLWithPath: $0) }
    }

    /// `pkgutil --check-signature`: signed when the status says so; the team is the `(XXXXXXXXXX)` of the first certificate.
    static func parsePackageSignature(_ output: String) -> (signed: Bool, team: String?) {
        var signed = false
        var team: String?
        for line in output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("Status:") {
                let status = line.lowercased()
                signed = status.contains("signed by a developer certificate issued by apple") || status.contains("signed apple software")
            }
            if team == nil, line.hasPrefix("1."), let range = line.range(of: #"\(([A-Z0-9]{10})\)$"#, options: .regularExpression) {
                team = String(line[range].dropFirst().dropLast())
            }
        }
        return (signed, team)
    }

    static func findApplication(in folder: URL, depth: Int = 2) -> URL? { find(extension: "app", in: folder, depth: depth) }

    static func find(extension ext: String, in folder: URL, depth: Int = 2) -> URL? {
        let items = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") && !ToolchainFiles.isSymbolicLink($0) && $0.lastPathComponent != "__MACOSX" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let match = items.first(where: { $0.pathExtension.lowercased() == ext }) { return match }
        guard depth > 1 else { return nil }
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && item.pathExtension.isEmpty {
            if let match = find(extension: ext, in: item, depth: depth - 1) { return match }
        }
        return nil
    }
}
