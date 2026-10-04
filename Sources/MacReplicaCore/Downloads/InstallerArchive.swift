import Foundation

/// An installer the user keeps for an app (a `.pkg`, `.dmg` or `.zip`, e.g. on an external drive): restoring from
/// it works without the internet and gives exactly the version the user had. Optionally copied into the backup.
///
/// Nothing in an installer is ever run by MacReplica: disk images are mounted read-only to read the app's
/// signature and version, packages are only checked with `pkgutil`. On the new Mac, packages open in Apple's
/// Installer for the user, apps are copied after their signature was checked.
public struct InstallerArchive: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case pkg, dmg, zip }

    /// The first 16 characters of the SHA-256.
    public var id: String
    public var fileName: String
    public var kind: Kind
    public var size: Int64
    public var sha256: String
    /// Developer team of the package signature or of the app inside.
    public var teamIdentifier: String?
    /// "Developer ID Installer: Example Inc (TEAMID1234)"; nil if not signed.
    public var signer: String?
    /// The package is signed by a Developer ID certificate that Apple issued.
    public var trustedSignature: Bool
    /// App found inside a disk image or zip archive.
    public var bundleIdentifier: String?
    public var version: String?
    public var architectures: [CPUArchitecture]
    /// Path inside the backup when the user chose to include the file.
    public var includedPath: String?
    /// Where the file was found (home folder written as `~`), e.g. on an external drive.
    public var originalPath: String
    /// The user marked the file as containing a licence (e.g. an activation package): it stays private to the
    /// backup, is never shown in reports beyond its name, and is only included when the user chooses so.
    public var containsLicence: Bool

    public init(id: String, fileName: String, kind: Kind, size: Int64, sha256: String, teamIdentifier: String? = nil, signer: String? = nil,
                trustedSignature: Bool = false, bundleIdentifier: String? = nil, version: String? = nil, architectures: [CPUArchitecture] = [],
                includedPath: String? = nil, originalPath: String, containsLicence: Bool = false) {
        self.id = id
        self.fileName = fileName
        self.kind = kind
        self.size = size
        self.sha256 = sha256
        self.teamIdentifier = teamIdentifier
        self.signer = signer
        self.trustedSignature = trustedSignature
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.architectures = architectures
        self.includedPath = includedPath
        self.originalPath = originalPath
        self.containsLicence = containsLicence
    }

    /// The installer belongs to the same developer as the installed app (when both are known).
    /// Only such installers are used automatically; others are shown with a warning and never opened by MacReplica.
    public func matchesDeveloper(of app: AppRecord) -> Bool {
        guard trustedSignature else { return false }
        guard let team = teamIdentifier, let appTeam = app.teamIdentifier else { return true }
        return team == appTeam
    }
}

public enum InstallerInspectionError: Error, Equatable, Sendable {
    case unsupportedType
    case unreadable
    /// The disk image has a licence agreement; it is only opened by the user.
    case licenseAgreement
}

/// Reads what an installer contains without running it.
public struct InstallerArchiveInspector: Sendable {
    public var layout: SystemLayout
    public var runner: CommandRunning

    public init(layout: SystemLayout, runner: CommandRunning) {
        self.layout = layout
        self.runner = runner
    }

    public static let supportedExtensions: Set<String> = ["pkg", "mpkg", "dmg", "zip"]

    public func inspect(_ file: URL, workFolder: URL) async throws -> InstallerArchive {
        let ext = file.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else { throw InstallerInspectionError.unsupportedType }
        guard let sha = try? Hashing.sha256Hex(ofFile: file),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw InstallerInspectionError.unreadable }
        var archive = InstallerArchive(id: String(sha.prefix(16)), fileName: file.lastPathComponent, kind: ext == "dmg" ? .dmg : (ext == "zip" ? .zip : .pkg),
                                       size: Int64(size), sha256: sha, originalPath: layout.displayPath(file))
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        let work = workFolder.appendingPathComponent("inspect-" + archive.id)
        defer { try? FileManager.default.removeItem(at: work) }
        try await describe(file, into: &archive, work: work, depth: 0)
        return archive
    }

    private var environment: [String: String] { layout.processEnvironment(homebrewPrefix: nil, askpass: nil) }

    private func describe(_ file: URL, into archive: inout InstallerArchive, work: URL, depth: Int) async throws {
        switch file.pathExtension.lowercased() {
        case "pkg", "mpkg":
            try await describePackage(file, into: &archive)
        case "dmg":
            try await describeDiskImage(file, into: &archive, work: work, depth: depth)
        case "zip":
            guard depth < 2 else { return }
            let folder = work.appendingPathComponent("zip-\(depth)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let result = try await runner.run(Command(executable: layout.ditto, arguments: ["-x", "-k", file.path, folder.path],
                                                      environment: environment, timeout: 900))
            guard result.succeeded else { throw InstallerInspectionError.unreadable }
            try await describeContents(of: folder, into: &archive, work: work, depth: depth + 1)
        case "app":
            describeApplication(file, into: &archive)
        default:
            break
        }
    }

    private func describeContents(of folder: URL, into archive: inout InstallerArchive, work: URL, depth: Int) async throws {
        for ext in ["app", "pkg", "mpkg", "dmg"] {
            if let found = DownloadInstaller.find(extension: ext, in: folder, depth: 2) {
                try await describe(found, into: &archive, work: work, depth: depth)
                return
            }
        }
    }

    private func describePackage(_ file: URL, into archive: inout InstallerArchive) async throws {
        let result = try await runner.run(Command(executable: layout.pkgutil, arguments: ["--check-signature", file.path], environment: environment, timeout: 120))
        let (signed, team) = DownloadInstaller.parsePackageSignature(result.stdout)
        archive.trustedSignature = result.succeeded && signed
        archive.teamIdentifier = archive.teamIdentifier ?? team
        archive.signer = Self.signer(result.stdout)
    }

    static func signer(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("1.") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
    }

    private func describeDiskImage(_ file: URL, into archive: inout InstallerArchive, work: URL, depth: Int) async throws {
        let info = try await DiskImageCommands.run(runner, Command(executable: layout.hdiutil, arguments: ["imageinfo", "-plist", file.path], environment: environment, timeout: 120))
        guard info.succeeded else { throw InstallerInspectionError.unreadable }
        if DownloadInstaller.hasLicenseAgreement(imageInfo: info.stdout) { throw InstallerInspectionError.licenseAgreement }
        let mountRoot = work.appendingPathComponent("mount-\(depth)")
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        let attach = try await DownloadInstaller.attachWithRetry(runner: runner, hdiutil: layout.hdiutil, environment: environment,
                                                                 arguments: ["attach", "-plist", "-nobrowse", "-readonly", "-noautoopen", "-mountrandom", mountRoot.path, file.path])
        guard attach.succeeded, let mountPoint = DownloadInstaller.mountPoint(fromAttachOutput: attach.stdout) else {
            throw InstallerInspectionError.unreadable
        }
        // Detached before returning, also after an error, so no image stays mounted.
        do {
            try await describeContents(of: mountPoint, into: &archive, work: work, depth: depth + 1)
        } catch {
            await detach(mountPoint)
            throw error
        }
        await detach(mountPoint)
    }

    private func detach(_ mountPoint: URL) async {
        let result = try? await DiskImageCommands.run(runner, Command(executable: layout.hdiutil, arguments: ["detach", mountPoint.path], environment: environment, timeout: 120))
        if result?.succeeded != true {
            _ = try? await DiskImageCommands.run(runner, Command(executable: layout.hdiutil, arguments: ["detach", "-force", mountPoint.path], environment: environment, timeout: 120))
        }
    }

    private func describeApplication(_ bundle: URL, into archive: inout InstallerArchive) {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else { return }
        archive.bundleIdentifier = info["CFBundleIdentifier"] as? String
        archive.version = info["CFBundleShortVersionString"] as? String
        if let executable = info["CFBundleExecutable"] as? String, !executable.contains("/") {
            archive.architectures = MachO.architectures(ofFile: bundle.appendingPathComponent("Contents/MacOS/\(executable)"))
        }
        if let identity = BundleInspection.signingIdentity(of: bundle) {
            archive.teamIdentifier = identity.teamIdentifier
            archive.trustedSignature = identity.teamIdentifier.map { BundleInspection.hasValidSignature(bundle, teamIdentifier: $0) } ?? false
        }
    }
}

/// Turns an app's recorded installers into a source for the guided installation on the new Mac.
public enum OwnInstallerSource {
    /// The file on this Mac: the copy in the backup, else the original location (e.g. the external drive, if connected).
    public static func locate(_ archive: InstallerArchive, backupRoot: URL?, layout: SystemLayout) -> URL? {
        if let path = archive.includedPath, let backupRoot, let url = PathSafety.resolve(path, inside: backupRoot),
           FileManager.default.fileExists(atPath: url.path) { return url }
        let original = layout.resolve(displayPath: archive.originalPath)
        return FileManager.default.fileExists(atPath: original.path) ? original : nil
    }

    /// Installers of the app that cannot be used here: not found, or not signed by the app's developer.
    public static func unusable(for app: AppRecord, backupRoot: URL?, layout: SystemLayout) -> [InstallerArchive] {
        (app.ownInstallers ?? []).filter { !$0.matchesDeveloper(of: app) || locate($0, backupRoot: backupRoot, layout: layout) == nil }
    }

    /// The offer for the app's own installers: the first is installed, the others follow as packages. Only
    /// installers signed by the app's developer are used, and only if the first one is available.
    public static func offer(for app: AppRecord, itemID: String, backupRoot: URL?, layout: SystemLayout) -> DownloadOffer? {
        let usable = (app.ownInstallers ?? []).filter { $0.matchesDeveloper(of: app) }
        guard let first = usable.first, let file = locate(first, backupRoot: backupRoot, layout: layout) else { return nil }
        var offer = DownloadOffer(id: "own:\(first.id)", itemID: itemID, kind: .ownInstaller, url: file.absoluteString,
                                  version: first.version ?? app.version, expectedLength: first.size, sha256: first.sha256,
                                  expectedBundleIdentifier: first.bundleIdentifier ?? app.bundleIdentifier,
                                  expectedTeamIdentifier: first.teamIdentifier, isPackage: first.kind == .pkg, recommended: true, trust: .checksum)
        offer.localPath = file.path
        offer.followUps = usable.dropFirst().compactMap { archive in
            guard archive.kind == .pkg, let url = locate(archive, backupRoot: backupRoot, layout: layout) else { return nil }
            return DownloadOffer.LocalPackage(name: archive.fileName, path: url.path, sha256: archive.sha256, teamIdentifier: archive.teamIdentifier)
        }
        return offer
    }
}
