import CoreServices
import CryptoKit
import Foundation

/// What a verified download contains and how it gets installed.
public enum PreparedDownload: Equatable, Sendable {
    /// A verified application bundle, ready to be copied into the Applications folder.
    case application(bundle: URL, mountPoint: URL?)
    /// A folder of apps that belong together (a suite such as DisplayCAL with its companion apps), installed as a whole
    /// into the Applications folder; `mainApp` was checked like a single application.
    case suite(folder: URL, mainApp: URL, mountPoint: URL?)
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
    /// Pause between attempts when macOS reports a disk image as busy (shorter in tests).
    public var retryPause: UInt64 = 1_000_000_000

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
            guard result.succeeded else {
                if offer.kind == .ownInstaller, offer.developerUnverified == true {
                    return .openInFinder(file, reason: .extractionFailed(InstallerArchiveInspector.note("ditto -x", result, redact: layout.redact)))
                }
                throw DownloadError.extractionFailed(layout.redact(result.combinedOutput))
            }
            if let app = Self.application(in: folder, bundleIdentifier: offer.expectedBundleIdentifier, depth: 2) {
                try checkApplication(app, offer: offer)
                return Self.prepared(app, container: folder, mountPoint: nil)
            }
            if let package = Self.find(extension: "pkg", in: folder) { return try await preparePackage(package, offer: offer) }
            // The user's confirmed installer with an unusual layout: shown in Finder for them.
            if offer.kind == .ownInstaller, offer.developerUnverified == true { return .openInFinder(file, reason: .noApplicationFound) }
            throw DownloadError.noApplicationFound
        case "dmg":
            return try await prepareDiskImage(file, offer: offer, staging: staging)
        default:
            return .openInFinder(file, reason: .noApplicationFound)
        }
    }

    func prepareDiskImage(_ file: URL, offer: DownloadOffer, staging: URL) async throws -> PreparedDownload {
        let environment = layout.processEnvironment(homebrewPrefix: nil, askpass: nil)
        // The user's own installer that they confirmed (its contents were not checked on the old Mac, or its developer is
        // unknown): if MacReplica cannot open it, Finder opens it for them. Its checksum was verified before this.
        let finderFallback = offer.kind == .ownInstaller && offer.developerUnverified == true
        func failed(_ step: String, _ result: CommandResult?) throws -> PreparedDownload {
            let detail = result.map { InstallerArchiveInspector.note(step, $0, redact: layout.redact) } ?? step
            if finderFallback { return .openInFinder(file, reason: .extractionFailed(detail)) }
            throw DownloadError.extractionFailed(detail)
        }
        // hdiutil would wait for the password of an encrypted image in a dialog; only the user can open it.
        if FileFormatEvidence.examine(file) == .encrypted { return try failed("password-protected disk image", nil) }
        let info = try await DiskImageCommands.run(runner, Command(executable: layout.hdiutil, arguments: ["imageinfo", "-plist", file.path],
                                                environment: environment, timeout: 120))
        guard info.succeeded else { return try failed("hdiutil imageinfo", info) }
        if Self.hasLicenseAgreement(imageInfo: info.stdout) {
            // The license must be accepted by the user; MacReplica never answers it.
            return .openInFinder(file, reason: .licenseAgreement)
        }
        let mountRoot = staging.appendingPathComponent("mount")
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        let attach = try await Self.attachWithRetry(runner: runner, hdiutil: layout.hdiutil, environment: environment, pause: retryPause,
                                                    arguments: ["attach", "-plist", "-nobrowse", "-readonly", "-noautoopen", "-mountrandom", mountRoot.path, file.path])
        guard attach.succeeded, let mountPoint = Self.mountPoint(fromAttachOutput: attach.stdout) else {
            if attach.succeeded, let device = Self.devices(fromAttachOutput: attach.stdout).first {
                // Attached without a volume: detached again, so nothing stays behind.
                _ = try? await DiskImageCommands.run(runner, Command(executable: layout.hdiutil, arguments: ["detach", device, "-force"], environment: environment, timeout: 120))
            }
            return try failed("hdiutil attach", attach)
        }
        do {
            if let app = Self.application(in: mountPoint, bundleIdentifier: offer.expectedBundleIdentifier, depth: 1) {
                try checkApplication(app, offer: offer)
                return Self.prepared(app, container: mountPoint, mountPoint: mountPoint)
            }
            if let package = Self.find(extension: "pkg", in: mountPoint, depth: 1) {
                // The package must stay readable after the image is detached, so it is copied out first.
                let copy = staging.appendingPathComponent(package.lastPathComponent)
                try FileManager.default.copyItem(at: package, to: copy)
                await detach(mountPoint)
                return try await preparePackage(copy, offer: offer)
            }
            if finderFallback {
                // An unusual layout the user confirmed on the old Mac: they install from it in Finder.
                await detach(mountPoint)
                return .openInFinder(file, reason: .noApplicationFound)
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
        guard result.succeeded, signed else {
            // The user confirmed this unverified installer on the old Mac: it is shown in Finder, where macOS asks
            // them to approve it. MacReplica never opens an unsigned package itself.
            if offer.developerUnverified == true, result.stdout.contains("Status:") { return .openInFinder(file, reason: .untrustedPackage("no trusted signature")) }
            throw DownloadError.untrustedPackage("no trusted signature")
        }
        if let expected = offer.expectedTeamIdentifier, team != expected { throw DownloadError.wrongDeveloper(expected: expected, actual: team) }
        return .package(file, teamIdentifier: team)
    }

    /// `hdiutil attach` can fail for a moment ("Resource temporarily unavailable") while another image is attached
    /// or Spotlight reads one; it is tried again with growing pauses. A failed attempt can still leave the image
    /// attached, so after the last failure every attachment of exactly this image is detached.
    static func attachWithRetry(runner: CommandRunning, hdiutil: String, environment: [String: String], pause: UInt64 = 1_000_000_000,
                                arguments: [String]) async throws -> CommandResult {
        // Attachments that existed before (the user opened the image in Finder) are never detached here.
        let image = arguments.last
        var before: Set<String> = []
        if let image { before = Set(await attachments(of: image, runner: runner, hdiutil: hdiutil, environment: environment).map(\.device)) }
        var result = try await DiskImageCommands.run(runner, Command(executable: hdiutil, arguments: arguments, environment: environment, timeout: 300))
        for attempt in 1...4 where !result.succeeded {
            try await Task.sleep(nanoseconds: UInt64(attempt) * pause)
            // A "failed" attempt may have attached the image anyway; it is detached before trying again,
            // so at most one attachment of MacReplica's exists afterwards.
            if let image { await detachAttachments(of: image, keeping: before, runner: runner, hdiutil: hdiutil, environment: environment) }
            result = try await DiskImageCommands.run(runner, Command(executable: hdiutil, arguments: arguments, environment: environment, timeout: 300))
        }
        if !result.succeeded, let image {
            await detachAttachments(of: image, keeping: before, runner: runner, hdiutil: hdiutil, environment: environment)
        }
        return result
    }

    /// The current attachments of the image at `path` (and only of it), as listed by `hdiutil info`: the whole-disk
    /// device and the first mount point, if any.
    static func attachments(of path: String, runner: CommandRunning, hdiutil: String, environment: [String: String]) async -> [(device: String, mountPoint: URL?)] {
        guard let info = try? await DiskImageCommands.run(runner, Command(executable: hdiutil, arguments: ["info", "-plist"], environment: environment, timeout: 60)),
              info.succeeded else { return [] }
        return attachments(of: path, infoPlist: info.stdout)
    }

    static func attachments(of path: String, infoPlist: String) -> [(device: String, mountPoint: URL?)] {
        let start = infoPlist.range(of: "<?xml")?.lowerBound ?? infoPlist.startIndex
        guard let plist = try? PropertyListSerialization.propertyList(from: Data(String(infoPlist[start...]).utf8), format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        let wanted = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return images.filter { ($0["image-path"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == wanted }.compactMap { image in
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            guard let device = entities.compactMap({ $0["dev-entry"] as? String }).min(by: { $0.count < $1.count }) else { return nil }
            return (device, entities.compactMap { $0["mount-point"] as? String }.first.map { URL(fileURLWithPath: $0) })
        }
    }

    /// Detaches the attachments of the image at `path` except those in `keeping`.
    static func detachAttachments(of path: String, keeping: Set<String> = [], runner: CommandRunning, hdiutil: String, environment: [String: String]) async {
        for attachment in await attachments(of: path, runner: runner, hdiutil: hdiutil, environment: environment) where !keeping.contains(attachment.device) {
            _ = try? await DiskImageCommands.run(runner, Command(executable: hdiutil, arguments: ["detach", attachment.device, "-force"], environment: environment, timeout: 120))
        }
    }

    /// The whole-disk device of an `hdiutil attach -plist` result (shortest `dev-entry`), for detaching it again.
    static func devices(fromAttachOutput plist: String) -> [String] {
        let start = plist.range(of: "<?xml")?.lowerBound ?? plist.startIndex
        guard let object = try? PropertyListSerialization.propertyList(from: Data(String(plist[start...]).utf8), format: nil) as? [String: Any],
              let entities = object["system-entities"] as? [[String: Any]] else { return [] }
        return entities.compactMap { $0["dev-entry"] as? String }.sorted { $0.count < $1.count }
    }

    /// Detaches the disk image. Right after copying an app the image can still be busy for a moment, so a
    /// failed detach is retried, the last time with `-force`; an image is never left mounted.
    public func detach(_ mountPoint: URL) async {
        let environment = layout.processEnvironment(homebrewPrefix: nil, askpass: nil)
        for attempt in 0..<3 {
            let arguments = attempt == 2 ? ["detach", "-force", mountPoint.path] : ["detach", mountPoint.path]
            let result = try? await DiskImageCommands.run(runner, Command(executable: layout.hdiutil, arguments: arguments, environment: environment, timeout: 120))
            if result?.succeeded == true { return }
            try? await Task.sleep(nanoseconds: retryPause)
        }
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

    /// Copies a verified suite folder into the Applications folder under `name` (the folder name on the old Mac), keeping
    /// every app's quarantine flag. An existing folder of that name is never replaced.
    public func installSuite(_ folder: URL, named name: String?, source: String) throws -> URL {
        guard let applications = layout.applicationFolders.first else { throw DownloadError.applicationsFolderNotWritable }
        let folderName = name.flatMap { PathSafety.isSafeRelativePath($0) && !$0.contains("/") ? $0 : nil } ?? folder.lastPathComponent
        let destination = applications.appendingPathComponent(folderName)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw DownloadError.alreadyInstalled }
        guard FileManager.default.isWritableFile(atPath: applications.path) else { throw DownloadError.applicationsFolderNotWritable }
        try FileManager.default.copyItem(at: folder, to: destination)
        for app in InstallerArchiveInspector.applications(in: destination) { try Self.quarantine(app, source: source) }
        return destination
    }

    // MARK: Parsing helpers

    /// `hdiutil imageinfo -plist` reports the licence agreement under `Properties` (seen on macOS 14 and 27 with the
    /// OnyX and SuperDuper! images); older output had it at the top level. Without this, `hdiutil attach` waits for an
    /// answer nobody gives and ends with "attach canceled".
    static func hasLicenseAgreement(imageInfo plist: String) -> Bool {
        let start = plist.range(of: "<?xml")?.lowerBound ?? plist.startIndex
        guard let data = String(plist[start...]).data(using: .utf8),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        let properties = object["Properties"] as? [String: Any] ?? [:]
        return (object["Software License Agreement"] as? Bool ?? false) || (properties["Software License Agreement"] as? Bool ?? false)
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

    /// The app with the expected bundle identifier, at the top of `folder` or in a suite folder one level down; without
    /// an expected identifier, the first app (as before: `depth` 1 for disk images, 2 for archives).
    static func application(in folder: URL, bundleIdentifier: String?, depth: Int) -> URL? {
        guard let expected = bundleIdentifier?.lowercased() else { return findApplication(in: folder, depth: depth) }
        return InstallerArchiveInspector.applications(in: folder).first { app in
            ((NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["CFBundleIdentifier"] as? String)?
                .lowercased() == expected
        }
    }

    /// A single app, or – when the app sits in a folder with further apps inside the container – that whole folder.
    static func prepared(_ app: URL, container: URL, mountPoint: URL?) -> PreparedDownload {
        let parent = app.deletingLastPathComponent()
        if parent.standardizedFileURL.path != container.standardizedFileURL.path,
           InstallerArchiveInspector.applications(in: parent).filter({ $0.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL }).count > 1 {
            return .suite(folder: parent, mainApp: app, mountPoint: mountPoint)
        }
        return .application(bundle: app, mountPoint: mountPoint)
    }

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
