import Foundation

/// An installer the user keeps for an app (a `.pkg`, `.dmg` or `.zip`, e.g. on an external drive): restoring from
/// it works without the internet and gives exactly the version the user had. Optionally copied into the backup.
///
/// Nothing in an installer is ever run by MacReplica: disk images are mounted read-only to read the app's
/// signature and version, packages are only checked with `pkgutil`. On the new Mac, packages open in Apple's
/// Installer for the user, apps are copied after their signature was checked.
public struct InstallerArchive: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// `app`: an application bundle chosen directly; it is stored as a zip archive of the bundle (`ditto`), which
    /// keeps its code signature, and it is always copied into the backup (the bundle itself has no single checksum).
    public enum Kind: String, Codable, Sendable { case pkg, dmg, zip, app }

    /// An application found inside the installer.
    public struct ContainedApp: Codable, Equatable, Hashable, Sendable {
        public var name: String
        public var bundleIdentifier: String?
        public var version: String?
        /// Path inside the installer, e.g. `DisplayCAL/3D LUT Maker.app`.
        public var path: String
        public init(name: String, bundleIdentifier: String?, version: String?, path: String) {
            self.name = name
            self.bundleIdentifier = bundleIdentifier
            self.version = version
            self.path = path
        }
    }

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
    /// The package, or the app inside, is signed with a Developer ID certificate that Apple issued and the signature is intact.
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
    /// Every app inside the installer (a suite such as DisplayCAL ships several). Empty for packages and when unknown.
    public var containedApps: [ContainedApp]
    /// A disk image with a licence agreement: MacReplica never answers it, so the contents are unknown and the
    /// image is opened in Finder for the user on the new Mac.
    public var hasLicenseAgreement: Bool
    /// The user confirmed using this installer although its developer cannot be verified (not signed with a
    /// Developer ID, e.g. ad-hoc signed free software). Only the user can set this; it never makes the file "verified".
    public var userApprovedUnverified: Bool
    /// An installer package (`.pkg`) was found: the file itself or inside a disk image or zip archive.
    public var containsPackage: Bool
    /// The file is intact as far as MacReplica can tell, but it could not look inside (see `ContentsLimit`). Like a
    /// disk image with a licence agreement, it is kept and used only after the user confirms it; on the new Mac it is
    /// opened in Finder. Nil when the contents were read.
    public var contentsLimit: ContentsLimit?
    /// What the checks found, for support (the tool, its exit status, its message; no personal data beyond the file name).
    public var inspectionNote: String?

    /// Why the contents of an intact installer are unknown. None of these means the file is damaged.
    public enum ContentsLimit: String, Codable, Equatable, Sendable, CaseIterable {
        /// A password-protected disk image: only the user can open it.
        case encrypted
        /// macOS could not open the disk image here, but its own checksum is intact (or it has none to check).
        case notMountable
        /// `hdiutil` could not read the image's description, but the image is structurally intact.
        case notReadable
        /// A check did not finish in time (e.g. a slow or sleeping drive).
        case timedOut
        /// Opened, but there is no app or installer package where MacReplica looks (an unusual layout).
        case notRecognised
        /// The zip archive is complete but could not be unpacked here (e.g. too little space, or protected).
        case notUnpacked
    }

    public init(id: String, fileName: String, kind: Kind, size: Int64, sha256: String, teamIdentifier: String? = nil, signer: String? = nil,
                trustedSignature: Bool = false, bundleIdentifier: String? = nil, version: String? = nil, architectures: [CPUArchitecture] = [],
                includedPath: String? = nil, originalPath: String, containsLicence: Bool = false, containedApps: [ContainedApp] = [],
                hasLicenseAgreement: Bool = false, userApprovedUnverified: Bool = false, containsPackage: Bool = false,
                contentsLimit: ContentsLimit? = nil, inspectionNote: String? = nil) {
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
        self.containedApps = containedApps
        self.hasLicenseAgreement = hasLicenseAgreement
        self.userApprovedUnverified = userApprovedUnverified
        self.containsPackage = containsPackage || kind == .pkg
        self.contentsLimit = contentsLimit
        self.inspectionNote = inspectionNote
    }

    private enum CodingKeys: String, CodingKey {
        case id, fileName, kind, size, sha256, teamIdentifier, signer, trustedSignature, bundleIdentifier, version, architectures
        case includedPath, originalPath, containsLicence, containedApps, hasLicenseAgreement, userApprovedUnverified, containsPackage
        case contentsLimit, inspectionNote
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        kind = try c.decode(Kind.self, forKey: .kind)
        size = try c.decode(Int64.self, forKey: .size)
        sha256 = try c.decode(String.self, forKey: .sha256)
        teamIdentifier = try c.decodeIfPresent(String.self, forKey: .teamIdentifier)
        signer = try c.decodeIfPresent(String.self, forKey: .signer)
        trustedSignature = try c.decodeIfPresent(Bool.self, forKey: .trustedSignature) ?? false
        bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        architectures = try c.decodeIfPresent([CPUArchitecture].self, forKey: .architectures) ?? []
        includedPath = try c.decodeIfPresent(String.self, forKey: .includedPath)
        originalPath = try c.decode(String.self, forKey: .originalPath)
        containsLicence = try c.decodeIfPresent(Bool.self, forKey: .containsLicence) ?? false
        containedApps = (try? c.decodeIfPresent([ContainedApp].self, forKey: .containedApps)) ?? []
        hasLicenseAgreement = try c.decodeIfPresent(Bool.self, forKey: .hasLicenseAgreement) ?? false
        userApprovedUnverified = try c.decodeIfPresent(Bool.self, forKey: .userApprovedUnverified) ?? false
        containsPackage = try c.decodeIfPresent(Bool.self, forKey: .containsPackage) ?? (kind == .pkg)
        // A reason written by a newer MacReplica that this one does not know still means "contents not inspected".
        if c.contains(.contentsLimit) {
            contentsLimit = (try? c.decode(ContentsLimit.self, forKey: .contentsLimit)) ?? .notReadable
        } else {
            contentsLimit = nil
        }
        inspectionNote = try c.decodeIfPresent(String.self, forKey: .inspectionNote)
    }

    /// MacReplica did not see what is inside: a licence agreement, or one of the `ContentsLimit` reasons.
    public var contentsUnknown: Bool { hasLicenseAgreement || contentsLimit != nil }

    /// Whether and how MacReplica may use the installer for an app.
    public enum Usability: Equatable, Sendable {
        /// Signed with a Developer ID by the app's developer (or, if the app's developer is unknown, by a Developer ID).
        case verified
        /// The developer cannot be verified (no Developer ID signature, or a disk image whose contents are behind a
        /// licence agreement). Used only after the user's explicit confirmation; the checksum still protects the file.
        case unverified(UnverifiedReason)
        /// Signed by a different developer than the installed app: never used.
        case otherDeveloper(String?)
        /// Contains a different app: never used.
        case differentApp(String)
    }

    public enum UnverifiedReason: String, Equatable, Sendable {
        /// No signature, or an ad-hoc signature (no developer identity).
        case notSigned
        /// A disk image with a licence agreement, or an intact installer MacReplica could not look inside
        /// (`contentsLimit`).
        case contentsNotInspected
    }

    public func usability(for app: AppRecord) -> Usability {
        if let wanted = app.bundleIdentifier?.lowercased() {
            let found = Set(([bundleIdentifier] + containedApps.map(\.bundleIdentifier)).compactMap { $0?.lowercased() })
            if !found.isEmpty, !found.contains(wanted) { return .differentApp(bundleIdentifier ?? containedApps.first?.bundleIdentifier ?? "") }
        }
        if contentsUnknown && !trustedSignature { return .unverified(.contentsNotInspected) }
        guard trustedSignature else { return .unverified(.notSigned) }
        if let team = teamIdentifier, let appTeam = app.teamIdentifier, team != appTeam { return .otherDeveloper(signer ?? team) }
        return .verified
    }

    /// The installer may be used on the new Mac: verified, or unverified and confirmed by the user.
    public func isUsable(for app: AppRecord) -> Bool {
        switch usability(for: app) {
        case .verified: return true
        case .unverified: return userApprovedUnverified
        case .otherDeveloper, .differentApp: return false
        }
    }

    /// The installer belongs to the same developer as the installed app (when both are known).
    /// Only such installers are used without asking; see `usability(for:)`.
    public func matchesDeveloper(of app: AppRecord) -> Bool {
        usability(for: app) == .verified
    }

    /// An app bundle chosen directly cannot be found again by checksum outside the backup, so it is always included.
    public var mustBeIncluded: Bool { kind == .app }
}

/// Why a chosen file is not used. Only `damaged` says the file is broken, and only when the file proves it; a file
/// that is intact but could not be inspected is kept instead (`InstallerArchive.contentsLimit`).
public enum InstallerInspectionError: Error, Equatable, Sendable {
    /// Not an installer MacReplica can use (only .pkg, .mpkg, .dmg, .zip and .app).
    case unsupportedType
    /// The file cannot be read (permissions, a drive that went away).
    case unreadable
    /// Proven damaged or incomplete; `DamageEvidence` says how it was established.
    case damaged(DamageEvidence)
    /// The name says installer, the bytes say something else (e.g. a web page saved instead of the download).
    case notAnInstaller(FileFormatEvidence.OtherFormat)
    /// macOS cannot open it as a disk image and it has no disk image structure MacReplica knows. Damage is not proven.
    case notRecognised
    /// An app chosen directly that has no `Contents/Info.plist`.
    case nothingInside
    /// Kept for compatibility; disk images with a licence agreement are recorded now (`hasLicenseAgreement`).
    case licenseAgreement

    public enum DamageEvidence: String, Equatable, Sendable {
        /// `hdiutil verify` rejected the disk image's own checksum.
        case checksumMismatch
        /// The file ends too early: the disk image's directory or the zip archive's central directory is missing.
        case truncated
    }
}

/// A rejection with what was checked, for the user's details line and the log.
public struct InstallerInspectionFailure: Error, Equatable, Sendable {
    public var error: InstallerInspectionError
    public var note: String?
    public init(_ error: InstallerInspectionError, note: String? = nil) {
        self.error = error
        self.note = note
    }
}

/// What choosing a file for an app produced: the installer, or why it cannot be used. Always shown to the user.
public struct InstallerSelection: Sendable {
    public var source: URL
    public var result: Result<Inspected, InstallerInspectionError>
    /// What the checks found when the file was not used (tool, exit status, message).
    public var note: String?

    public struct Inspected: Sendable {
        public var archive: InstallerArchive
        /// The file that is copied into the backup: the chosen file itself, or a zip of a chosen app bundle.
        public var file: URL
    }

    public init(source: URL, result: Result<Inspected, InstallerInspectionError>, note: String? = nil) {
        self.source = source
        self.result = result
        self.note = note
    }
}

/// Reads what an installer contains without running it.
public struct InstallerArchiveInspector: Sendable {
    public var layout: SystemLayout
    public var runner: CommandRunning
    /// Pause between attempts when macOS reports a disk image as busy (shorter in tests).
    public var retryPause: UInt64 = 1_000_000_000

    public init(layout: SystemLayout, runner: CommandRunning) {
        self.layout = layout
        self.runner = runner
    }

    public static let supportedExtensions: Set<String> = ["pkg", "mpkg", "dmg", "zip", "app"]

    /// Inspects a chosen file and never fails silently: the result says what it is or why it cannot be used.
    /// An app bundle is packed into a zip in `bundleStore` (with `ditto`, which keeps its signature) so it can be
    /// checksummed and copied into the backup.
    public func select(_ file: URL, workFolder: URL, bundleStore: URL) async -> InstallerSelection {
        do {
            if file.pathExtension.lowercased() == "app" {
                let (archive, zip) = try await inspectBundle(file, bundleStore: bundleStore)
                return InstallerSelection(source: file, result: .success(.init(archive: archive, file: zip)))
            }
            let archive = try await inspect(file, workFolder: workFolder)
            return InstallerSelection(source: file, result: .success(.init(archive: archive, file: file)))
        } catch let failure as InstallerInspectionFailure {
            return InstallerSelection(source: file, result: .failure(failure.error), note: failure.note)
        } catch let error as InstallerInspectionError {
            return InstallerSelection(source: file, result: .failure(error))
        } catch {
            return InstallerSelection(source: file, result: .failure(.unreadable), note: layout.redact(String(describing: error)))
        }
    }

    public func inspect(_ file: URL, workFolder: URL) async throws -> InstallerArchive {
        let ext = file.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext), ext != "app" else { throw InstallerInspectionError.unsupportedType }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let sha = try? Hashing.sha256Hex(ofFile: file),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw InstallerInspectionError.unreadable }
        var archive = InstallerArchive(id: String(sha.prefix(16)), fileName: file.lastPathComponent, kind: ext == "dmg" ? .dmg : (ext == "zip" ? .zip : .pkg),
                                       size: Int64(size), sha256: sha, originalPath: layout.displayPath(file))
        try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
        // A folder of its own for every inspection: two inspections of the same file (or a clean-up of another one)
        // must never remove the folder an image is being mounted in.
        let work = workFolder.appendingPathComponent("inspect-\(archive.id)-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: work) }
        try await describe(file, into: &archive, work: work, depth: 0)
        if !archive.containsPackage, !archive.contentsUnknown, archive.containedApps.isEmpty {
            // Opened, but no app or package where MacReplica looks: the file is fine, only its layout is unusual. It
            // is kept for the user to confirm and opened in Finder on the new Mac.
            archive.contentsLimit = .notRecognised
            archive.inspectionNote = archive.inspectionNote ?? "opened; no app or installer package found in the top two folder levels"
        }
        return archive
    }

    /// An app bundle chosen directly: described, then packed into a zip whose checksum identifies it.
    func inspectBundle(_ bundle: URL, bundleStore: URL) async throws -> (InstallerArchive, URL) {
        guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Info.plist").path) else {
            throw InstallerInspectionError.nothingInside
        }
        try FileManager.default.createDirectory(at: bundleStore, withIntermediateDirectories: true)
        let name = bundle.lastPathComponent + ".zip"
        let temporary = bundleStore.appendingPathComponent(UUID().uuidString + ".zip")
        let result = try await runner.run(Command(executable: layout.ditto, arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", bundle.path, temporary.path],
                                                  environment: environment, timeout: 1800))
        guard result.succeeded, let sha = try? Hashing.sha256Hex(ofFile: temporary),
              let size = try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            try? FileManager.default.removeItem(at: temporary)
            throw InstallerInspectionError.unreadable
        }
        let folder = bundleStore.appendingPathComponent(String(sha.prefix(16)))
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: temporary, to: zip)
        var archive = InstallerArchive(id: String(sha.prefix(16)), fileName: name, kind: .app, size: Int64(size), sha256: sha,
                                       originalPath: layout.displayPath(bundle))
        describeApplications([bundle], root: bundle.deletingLastPathComponent(), into: &archive)
        return (archive, zip)
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
            if case .otherFormat(let other)? = FileFormatEvidence.examine(file), other != .zipArchive {
                throw InstallerInspectionFailure(.notAnInstaller(other), note: "the file is not a zip archive (\(other.rawValue))")
            }
            if ZipEvidence.hasCentralDirectory(file) == false {
                throw InstallerInspectionFailure(.damaged(.truncated), note: "zip archive without its central directory (the end of the file is missing)")
            }
            let folder = work.appendingPathComponent("zip-\(depth)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let result = try await runner.run(Command(executable: layout.ditto, arguments: ["-x", "-k", file.path, folder.path],
                                                      environment: environment, timeout: 900))
            guard result.succeeded else {
                // A complete archive that could not be unpacked here (space, protection): kept, not called damaged.
                limit(&archive, result.timedOut ? .timedOut : .notUnpacked, note: note("ditto -x", result))
                return
            }
            try await describeContents(of: folder, into: &archive, work: work, depth: depth + 1)
        default:
            break
        }
    }

    /// Apps directly inside the folder or one folder down (a suite folder such as `DisplayCAL/`), else a package or a
    /// nested disk image.
    private func describeContents(of folder: URL, into archive: inout InstallerArchive, work: URL, depth: Int) async throws {
        let apps = Self.applications(in: folder)
        if !apps.isEmpty {
            describeApplications(apps, root: folder, into: &archive)
            return
        }
        for ext in ["pkg", "mpkg", "dmg"] {
            if let found = DownloadInstaller.find(extension: ext, in: folder, depth: 2) {
                try await describe(found, into: &archive, work: work, depth: depth)
                return
            }
        }
    }

    /// `.app` bundles at the top of `folder` and in its subfolders (one level), sorted by path.
    static func applications(in folder: URL) -> [URL] {
        func list(_ url: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") && !ToolchainFiles.isSymbolicLink($0) && $0.lastPathComponent != "__MACOSX" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        var result: [URL] = []
        for item in list(folder) {
            if item.pathExtension.lowercased() == "app" { result.append(item); continue }
            guard item.pathExtension.isEmpty, (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            result += list(item).filter { $0.pathExtension.lowercased() == "app" }
        }
        return result
    }

    private func describePackage(_ file: URL, into archive: inout InstallerArchive) async throws {
        let evidence = FileFormatEvidence.examine(file)
        if case .otherFormat(let other)? = evidence, other != .installerPackage {
            throw InstallerInspectionFailure(.notAnInstaller(other), note: "the file is not an installer package (\(other.rawValue))")
        }
        if evidence != nil, evidence != .otherFormat(.installerPackage), !Self.isPackageFolder(file) {
            throw InstallerInspectionFailure(.notRecognised, note: "no installer package header (xar) at the start of the file")
        }
        let result = try await runner.run(Command(executable: layout.pkgutil, arguments: ["--check-signature", file.path], environment: environment, timeout: 120))
        // An unsigned package still reports a status ("no signature"). Without one, the package header was found but
        // pkgutil could not check it: the package is kept with its contents unchecked rather than called damaged.
        guard result.stdout.contains("Status:") else {
            archive.containsPackage = true
            limit(&archive, result.timedOut ? .timedOut : .notReadable, note: note("pkgutil --check-signature", result))
            return
        }
        // pkgutil checks the package's own checksum: "Status: package is invalid (checksum did not verify)" for a package
        // that was cut short or changed. Before 1.1 this counted as "not signed".
        if Self.packageIsInvalid(result.stdout) {
            throw InstallerInspectionFailure(.damaged(.checksumMismatch), note: note("pkgutil --check-signature", result))
        }
        let (signed, team) = DownloadInstaller.parsePackageSignature(result.stdout)
        archive.containsPackage = true
        archive.trustedSignature = result.succeeded && signed
        archive.teamIdentifier = archive.teamIdentifier ?? team
        archive.signer = Self.signer(result.stdout)
    }

    static func packageIsInvalid(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .contains { $0.hasPrefix("status:") && $0.contains("package is invalid") }
    }

    static func signer(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("1.") }.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
    }

    /// Bundle-style packages (`.pkg`/`.mpkg` folders) are not files; they are reported as unreadable before this.
    static func isPackageFolder(_ file: URL) -> Bool {
        (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// The steps of a disk image, each with its own verdict: the file's bytes (encrypted, cut short, something else),
    /// the image description (`imageinfo`), mounting, then the contents. Only the bytes or the image's own checksum
    /// (`hdiutil verify`) can prove damage; every other failure keeps the image with its contents unchecked.
    private func describeDiskImage(_ file: URL, into archive: inout InstallerArchive, work: URL, depth: Int) async throws {
        let evidence = FileFormatEvidence.examine(file)
        switch evidence {
        case nil:
            throw InstallerInspectionFailure(.unreadable, note: "the file could not be read")
        case .encrypted?:
            // hdiutil would wait for the password in a dialog; MacReplica never asks for it.
            limit(&archive, .encrypted, note: "password-protected disk image; not opened")
            return
        case .otherFormat(let other)?:
            throw InstallerInspectionFailure(.notAnInstaller(other), note: "the file is not a disk image (\(other.rawValue))")
        case .udifTruncated?, .compressedImageWithoutDirectory?:
            throw InstallerInspectionFailure(.damaged(.truncated), note: "the disk image's directory at the end of the file is missing or points past its end")
        case .udif?, .rawImage?, .unknown?:
            break
        }
        let info = try await DiskImageCommands.run(runner, Command(executable: layout.hdiutil, arguments: ["imageinfo", "-plist", file.path], environment: environment, timeout: 120))
        guard info.succeeded else {
            if info.timedOut {
                limit(&archive, .timedOut, note: note("hdiutil imageinfo", info))
                return
            }
            if evidence == .unknown { throw InstallerInspectionFailure(.notRecognised, note: note("hdiutil imageinfo", info)) }
            let checksum = try await verifyChecksum(file, evidence: evidence, after: note("hdiutil imageinfo", info))
            limit(&archive, .notReadable, note: note("hdiutil imageinfo", info) + "; " + checksum)
            return
        }
        if DownloadInstaller.hasLicenseAgreement(imageInfo: info.stdout) {
            // MacReplica never answers a licence agreement: the image is recorded, its contents stay unknown.
            archive.hasLicenseAgreement = true
            return
        }
        // Already open, e.g. still mounted in Finder after installing from it: read where it is. It stays open – macOS
        // refuses a second attachment ("resource busy"), and ejecting the user's volume is not MacReplica's business.
        let existing = await DownloadInstaller.attachments(of: file.path, runner: runner, hdiutil: layout.hdiutil, environment: environment)
        if let open = existing.compactMap(\.mountPoint).first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            try await describeContents(of: open, into: &archive, work: work, depth: depth + 1)
            archive.inspectionNote = archive.inspectionNote ?? "read where the image was already open"
            return
        }
        if !existing.isEmpty {
            // Attached by another program without a volume: an attach would reuse (and a clean-up detach) that device.
            limit(&archive, .notMountable, note: "already attached by another program without a volume; left as it is")
            return
        }
        let mountRoot = work.appendingPathComponent("mount-\(depth)")
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)
        let attach = try await DownloadInstaller.attachWithRetry(runner: runner, hdiutil: layout.hdiutil, environment: environment, pause: retryPause,
                                                                 arguments: ["attach", "-plist", "-nobrowse", "-readonly", "-noautoopen", "-mountrandom", mountRoot.path, file.path])
        guard attach.succeeded, let mountPoint = DownloadInstaller.mountPoint(fromAttachOutput: attach.stdout) else {
            if attach.succeeded {
                // Attached without a volume (no file system macOS can mount): detached again, nothing stays behind.
                for device in DownloadInstaller.devices(fromAttachOutput: attach.stdout).prefix(1) {
                    _ = try? await DiskImageCommands.run(runner, Command(executable: layout.hdiutil, arguments: ["detach", device, "-force"], environment: environment, timeout: 120))
                }
            }
            if attach.timedOut {
                limit(&archive, .timedOut, note: note("hdiutil attach", attach))
                return
            }
            let checksum = try await verifyChecksum(file, evidence: evidence, after: note("hdiutil attach", attach))
            limit(&archive, .notMountable, note: note("hdiutil attach", attach) + "; " + checksum)
            return
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

    /// After a failed step, the image's own checksum decides. Damage needs proof: `hdiutil verify -plist` reporting a
    /// calculated checksum that differs from the expected one (structured, so independent of the user's language).
    /// Any other failure is no proof – a release run saw an intact image called damaged because `hdiutil verify` failed
    /// with “Resource temporarily unavailable” (the disk-image service was busy, 2026-10-18). Such a failure is tried
    /// again; if it stays, the image is kept with its contents unchecked. Returns what was found, for the note.
    @discardableResult
    private func verifyChecksum(_ file: URL, evidence: FileFormatEvidence?, after step: String) async throws -> String {
        guard evidence == .udif(hasChecksum: true) else { return "no checksum to verify" }
        var last: CommandResult?
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: retryPause * UInt64(attempt)) }
            let verify = try await DiskImageCommands.run(runner, Command(executable: layout.hdiutil, arguments: ["verify", "-plist", file.path],
                                                                         environment: environment, timeout: 900))
            if verify.timedOut { return "checksum not checked in time" }
            if let checksums = Self.checksums(inVerifyOutput: verify.stdout) {
                guard checksums.calculated == checksums.expected else {
                    throw InstallerInspectionFailure(.damaged(.checksumMismatch),
                                                     note: step + "; hdiutil verify: calculated \(checksums.calculated), expected \(checksums.expected)")
                }
                return "checksum verified"
            }
            if verify.succeeded { return "checksum verified" }
            last = verify
        }
        return "checksum not checked – " + (last.map { note("hdiutil verify", $0) } ?? "hdiutil verify did not run")
    }

    /// The calculated and expected checksum from `hdiutil verify -plist`, or nil when the output has no such report.
    static func checksums(inVerifyOutput output: String) -> (calculated: String, expected: String)? {
        guard let start = output.range(of: "<?xml"), let data = String(output[start.lowerBound...]).data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        func value(_ key: String) -> String? {
            guard let entry = plist[key] as? [String: Any], let value = entry["Checksum Value"] as? String, !value.isEmpty else { return nil }
            return ((entry["Checksum Type"] as? String) ?? "") + " " + value
        }
        guard let calculated = value("calculated"), let expected = value("expected") else { return nil }
        return (calculated, expected)
    }

    private func limit(_ archive: inout InstallerArchive, _ limit: InstallerArchive.ContentsLimit, note: String) {
        archive.contentsLimit = archive.contentsLimit ?? limit
        archive.inspectionNote = archive.inspectionNote ?? note
    }

    /// "hdiutil attach: exit 1 – <message>": the tool's own words (in the user's language), without deprecation
    /// warnings and with the home folder hidden.
    func note(_ step: String, _ result: CommandResult) -> String {
        Self.note(step, result, redact: layout.redact)
    }

    static func note(_ step: String, _ result: CommandResult, redact: (String) -> String) -> String {
        if result.timedOut { return "\(step): did not finish in time" }
        let message = (result.stderr + "\n" + result.stdout).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("WARNING") && !$0.hasPrefix("<") }
            .last.map { redact(String($0.prefix(200))) }
        return "\(step): exit \(result.exitCode)" + (message.map { " – " + $0 } ?? "")
    }

    private func detach(_ mountPoint: URL) async {
        let result = try? await DiskImageCommands.run(runner, Command(executable: layout.hdiutil, arguments: ["detach", mountPoint.path], environment: environment, timeout: 120))
        if result?.succeeded != true {
            _ = try? await DiskImageCommands.run(runner, Command(executable: layout.hdiutil, arguments: ["detach", "-force", mountPoint.path], environment: environment, timeout: 120))
        }
    }

    /// Records every app; the main app (identity, version, signature) is the one whose bundle identifier the others
    /// extend (DisplayCAL: `net.displaycal.DisplayCAL` and `net.displaycal.DisplayCAL-3DLUT-maker` …), else the first.
    private func describeApplications(_ bundles: [URL], root: URL, into archive: inout InstallerArchive) {
        var contained: [(URL, InstallerArchive.ContainedApp)] = []
        for bundle in bundles {
            let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
            let relative = FileScanner.relativePath(of: bundle, below: root) ?? bundle.lastPathComponent
            contained.append((bundle, .init(name: bundle.deletingPathExtension().lastPathComponent, bundleIdentifier: info["CFBundleIdentifier"] as? String,
                                            version: info["CFBundleShortVersionString"] as? String, path: relative)))
        }
        archive.containedApps = contained.map(\.1)
        guard let main = Self.mainApp(contained.map(\.1)).flatMap({ wanted in contained.first { $0.1 == wanted } }) else { return }
        let bundle = main.0
        let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        archive.bundleIdentifier = info["CFBundleIdentifier"] as? String
        archive.version = info["CFBundleShortVersionString"] as? String
        if let executable = info["CFBundleExecutable"] as? String, !executable.contains("/") {
            archive.architectures = MachO.architectures(ofFile: bundle.appendingPathComponent("Contents/MacOS/\(executable)"))
        }
        if let identity = BundleInspection.signingIdentity(of: bundle) {
            archive.teamIdentifier = identity.teamIdentifier
            archive.trustedSignature = identity.teamIdentifier.map { BundleInspection.hasValidSignature(bundle, teamIdentifier: $0) } ?? false
            if archive.trustedSignature, let vendor = BundleInspection.signingVendor(of: bundle) { archive.signer = vendor }
        }
    }

    static func mainApp(_ apps: [InstallerArchive.ContainedApp]) -> InstallerArchive.ContainedApp? {
        let identified = apps.filter { $0.bundleIdentifier != nil }
        let extended = identified.first { candidate in
            let prefix = candidate.bundleIdentifier!.lowercased()
            return identified.contains { $0 != candidate && $0.bundleIdentifier!.lowercased().hasPrefix(prefix) }
        }
        return extended ?? apps.first
    }
}

/// Turns an app's recorded installers into a source for the guided installation on the new Mac.
public enum OwnInstallerSource {
    /// The file on this Mac: the copy in the backup, else the original location (e.g. the external drive, if connected).
    /// An app bundle chosen directly is only found in the backup (its zip is what was checksummed).
    public static func locate(_ archive: InstallerArchive, backupRoot: URL?, layout: SystemLayout) -> URL? {
        if let path = archive.includedPath, let backupRoot, let url = PathSafety.resolve(path, inside: backupRoot),
           FileManager.default.fileExists(atPath: url.path) { return url }
        guard archive.kind != .app else { return nil }
        let original = layout.resolve(displayPath: archive.originalPath)
        return FileManager.default.fileExists(atPath: original.path) ? original : nil
    }

    /// Installers of the app that cannot be used here: not found, signed by someone else, a different app, or
    /// unverified without the user's confirmation.
    public static func unusable(for app: AppRecord, backupRoot: URL?, layout: SystemLayout) -> [InstallerArchive] {
        (app.ownInstallers ?? []).filter { !$0.isUsable(for: app) || locate($0, backupRoot: backupRoot, layout: layout) == nil }
    }

    /// The offer for the app's own installers: the first is installed, the others follow as packages. Only installers
    /// signed by the app's developer – or unverified ones the user confirmed – are used, and only if the first one is available.
    public static func offer(for app: AppRecord, itemID: String, backupRoot: URL?, layout: SystemLayout) -> DownloadOffer? {
        let usable = (app.ownInstallers ?? []).filter { $0.isUsable(for: app) }
        guard let first = usable.first, let file = locate(first, backupRoot: backupRoot, layout: layout) else { return nil }
        let unverified = first.usability(for: app) != .verified
        var offer = DownloadOffer(id: "own:\(first.id)", itemID: itemID, kind: .ownInstaller, url: file.absoluteString,
                                  version: first.version ?? app.version, expectedLength: first.size, sha256: first.sha256,
                                  expectedBundleIdentifier: app.bundleIdentifier ?? first.bundleIdentifier,
                                  expectedTeamIdentifier: unverified ? nil : first.teamIdentifier,
                                  isPackage: first.kind == .pkg, recommended: true, trust: .checksum)
        offer.localPath = file.path
        offer.developerUnverified = unverified ? true : nil
        offer.suiteFolderName = app.suiteFolderName
        offer.followUps = usable.dropFirst().compactMap { archive in
            guard archive.kind == .pkg, let url = locate(archive, backupRoot: backupRoot, layout: layout) else { return nil }
            var package = DownloadOffer.LocalPackage(name: archive.fileName, path: url.path, sha256: archive.sha256, teamIdentifier: archive.teamIdentifier)
            package.developerUnverified = archive.usability(for: app) != .verified ? true : nil
            return package
        }
        return offer
    }
}
