import Foundation

/// Where creating a bootable installer is.
public enum InstallMediaStage: Equatable, Sendable {
    /// `softwareupdate --fetch-full-installer`; the percentage Software Update reports, if it has said one yet.
    case downloading(percent: Double?)
    case checkingInstaller
    /// Reading the drive again: is it still the one the user confirmed?
    case checkingDrive
    case erasing
    /// The password dialog, then Apple's `createinstallmedia` (it reports no progress MacReplica could show).
    case creating
    case verifying
}

public enum InstallMediaError: Error, Equatable, Sendable {
    case downloadFailed(String)
    /// The download finished but no installer with Apple's name for the release is in Applications.
    case installerNotFound(String)
    case installerUnusable([InstallerAppProblem])
    case drive(InstallMediaDriveError)
    case eraseFailed(String)
    /// After erasing, the drive did not show the volume MacReplica named.
    case volumeMissing
    case passwordDenied
    case createFailed(String)
    /// Refused before anything happened (e.g. a simulated Mac pointing at the real `diskutil`).
    case refused(String)
}

/// One check of the finished drive.
public struct InstallMediaCheck: Equatable, Sendable {
    public enum Item: String, Sendable { case volumeOnDrive, format, installerApp, installerVersion, startupFiles, blessed, signature }
    public var item: Item
    public var passed: Bool
    public var detail: String
}

public struct InstallMediaResult: Equatable, Sendable {
    public var verification: ToolVerification
    public var volume: URL?
    public var checks: [InstallMediaCheck]
}

/// Downloads an installer and writes it to a drive – every destructive step exactly once, never retried by itself.
///
/// The order is fixed: check the installer, read the drive again and compare it with what the user confirmed, erase
/// it (as the user: `diskutil` erases external drives without administrator rights) to one Mac OS Extended
/// (Journaled) volume with a random name, put a random marker on it, then – after the password – check the marker
/// and run Apple's `createinstallmedia` on exactly that volume, and finally read the result back.
public struct InstallMediaCreator: Sendable {
    public var layout: SystemLayout
    public var runner: CommandRunning
    public var privileged: PrivilegedExecuting
    public var scanner: InstallMediaDriveScanner
    public var inspector: InstallerInspector

    public init(layout: SystemLayout, runner: CommandRunning, privileged: PrivilegedExecuting, scanner: InstallMediaDriveScanner,
                inspector: InstallerInspector) {
        self.layout = layout
        self.runner = runner
        self.privileged = privileged
        self.scanner = scanner
        self.inspector = inspector
    }

    // MARK: Download

    /// "Installing: 45.0%" → 45.
    public static func downloadPercent(in line: String) -> Double? {
        guard let match = line.range(of: #"(Installing|Downloading):\s*([0-9]{1,3}(\.[0-9]+)?)%"#, options: .regularExpression) else { return nil }
        let text = line[match].split(separator: ":").last?.trimmingCharacters(in: .whitespaces).dropLast() ?? ""
        return Double(text).map { min(max($0, 0), 100) }
    }

    /// Asks Software Update for the full installer of `release` and returns the installer app it placed in
    /// Applications. Cancelling the task stops the download.
    public func download(_ release: MacOSRelease, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        guard release.source == .softwareUpdate, let version = release.version, MacOSInstallerCatalog.isVersion(version) else {
            throw InstallMediaError.refused("only Software Update's installers are downloaded by MacReplica")
        }
        progress(nil)
        let result = try await runner.run(Command(executable: layout.softwareupdate,
                                                  arguments: ["--fetch-full-installer", "--full-installer-version", version],
                                                  environment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil), timeout: 6 * 3600)) { line in
            if let percent = Self.downloadPercent(in: line) { progress(percent) }
        }
        try Task.checkCancellation()
        let output = result.combinedOutput.lowercased()
        // softwareupdate can exit 0 after an error message, so its words count as well.
        guard result.succeeded, !output.contains("install failed"), !output.contains("error") else {
            throw InstallMediaError.downloadFailed(result.timedOut ? "Software Update did not finish in time"
                : layout.redact(ErrorClassifier.technicalDetail(result.combinedOutput, layout: layout, maxLines: 3)))
        }
        guard let app = inspector.installer(for: release) else { throw InstallMediaError.installerNotFound(release.installerAppName) }
        return app
    }

    // MARK: Create

    /// The random name of the erased volume (`MRINSTALL-` + 8 hex digits).
    public static func makeVolumeName() -> String {
        "MRINSTALL-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8))
    }

    public func create(installer report: InstallerAppReport, on confirmed: InstallMediaDrive,
                       stage: @escaping @Sendable (InstallMediaStage) -> Void) async throws -> InstallMediaResult {
        // A simulated Mac never reaches the real diskutil or a real drive.
        if layout.isSimulation, layout.diskutil == SystemLayout.realDiskutil {
            throw InstallMediaError.refused("simulated Mac without a stand-in diskutil")
        }
        stage(.checkingInstaller)
        let problems = inspector.problems(of: report)
        guard problems.isEmpty, let tool = report.createInstallMedia else { throw InstallMediaError.installerUnusable(problems) }

        stage(.checkingDrive)
        let drive: InstallMediaDrive
        do { drive = try await scanner.revalidate(confirmed, required: report.requiredBytes) } catch let error as InstallMediaDriveError {
            throw InstallMediaError.drive(error)
        }
        guard InstallMediaDrive.isWholeDiskIdentifier(drive.device) else { throw InstallMediaError.drive(.driveChanged) }

        stage(.erasing)
        let name = Self.makeVolumeName()
        let erase = try await runner.run(Command(executable: layout.diskutil, arguments: ["eraseDisk", "JHFS+", name, "GPT", drive.device],
                                                 environment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil), timeout: 900))
        guard erase.succeeded else {
            throw InstallMediaError.eraseFailed(layout.redact(ErrorClassifier.technicalDetail(erase.combinedOutput, layout: layout, maxLines: 3)))
        }
        let volume = layout.volumesRoot.appendingPathComponent(name)
        guard try await volumeMount(named: name, on: drive.device) == volume.path else { throw InstallMediaError.volumeMissing }
        let marker = volume.appendingPathComponent(".MacReplicaInstallTarget-\(UUID().uuidString)")
        do { try Data().write(to: marker) } catch { throw InstallMediaError.volumeMissing }

        stage(.creating)
        let applicationPath = report.needsApplicationPath ? report.app : nil
        do {
            try await privileged.run([.requireInstallMediaMarker(marker), .createInstallMedia(tool: tool, volume: volume, applicationPath: applicationPath)],
                                     reason: "MacReplica wants to create a bootable macOS installer on “\(drive.mediaName)”.")
        } catch PrivilegedError.denied {
            throw InstallMediaError.passwordDenied
        } catch PrivilegedError.failed(let output) {
            throw InstallMediaError.createFailed(layout.redact(ErrorClassifier.technicalDetail(output, layout: layout, maxLines: 4)))
        } catch {
            throw InstallMediaError.createFailed(layout.redact(String(describing: error)))
        }

        stage(.verifying)
        return await verify(drive: drive, installer: report)
    }

    /// The mount point of the volume called `name` on `device`, read from diskutil.
    func volumeMount(named name: String, on device: String) async throws -> String? {
        try await partitions(of: device).first { $0.name == name }?.mountPoint
    }

    func partitions(of device: String) async throws -> [InstallMediaDrive.Volume] {
        let list = try await scanner.plist(["list", "-plist", device])
        let entry = (list["AllDisksAndPartitions"] as? [[String: Any]] ?? []).first { $0["DeviceIdentifier"] as? String == device } ?? [:]
        return InstallMediaDriveScanner.drive(device: device, list: entry, info: [:]).volumes
    }

    // MARK: Verify

    /// Reads the finished drive: Apple's installer volume on the confirmed drive, Mac OS Extended, the installer app
    /// in the version that was used, its startup files, the startup folder set, and Apple's signature intact. A
    /// drive can only really be proven by starting a Mac from it; this is everything short of that.
    public func verify(drive: InstallMediaDrive, installer: InstallerAppReport) async -> InstallMediaResult {
        var checks: [InstallMediaCheck] = []
        let volumes = (try? await partitions(of: drive.device)) ?? []
        let installerVolume = volumes.first { $0.name == installer.displayName && $0.mountPoint != nil }
        checks.append(.init(item: .volumeOnDrive, passed: installerVolume != nil,
                            detail: installerVolume.map { "\($0.device): \($0.name)" } ?? "no volume “\(installer.displayName)” on \(drive.device)"))
        guard let installerVolume, let mount = installerVolume.mountPoint else {
            return InstallMediaResult(verification: .failed, volume: nil, checks: checks)
        }
        let root = URL(fileURLWithPath: mount)
        checks.append(.init(item: .format, passed: installerVolume.content == "Apple_HFS", detail: installerVolume.content))
        let app = root.appendingPathComponent(installer.app.lastPathComponent)
        let info = InstallerInspector.plist(app.appendingPathComponent("Contents/Info.plist"))
        checks.append(.init(item: .installerApp, passed: info != nil, detail: app.lastPathComponent))
        let copiedVersion = info?["CFBundleShortVersionString"] as? String
        checks.append(.init(item: .installerVersion, passed: copiedVersion != nil && copiedVersion == installer.appVersion,
                            detail: "\(copiedVersion ?? "–") / \(installer.appVersion ?? "–")"))
        let bootFile = root.appendingPathComponent("System/Library/CoreServices/boot.efi")
        checks.append(.init(item: .startupFiles, passed: FileManager.default.fileExists(atPath: bootFile.path), detail: "System/Library/CoreServices/boot.efi"))
        let bless = try? await runner.run(Command(executable: layout.bless, arguments: ["--info", mount], timeout: 60))
        let blessed = bless.map { $0.succeeded && $0.stdout.contains("CoreServices") } ?? false
        checks.append(.init(item: .blessed, passed: blessed,
                            detail: bless.map { layout.redact(ErrorClassifier.technicalDetail($0.combinedOutput, layout: layout, maxLines: 2)) } ?? "bless could not be run"))
        let signature = try? await runner.run(Command(executable: layout.codesign, arguments: ["--verify", "--strict", "-R=anchor apple", app.path], timeout: 1800))
        checks.append(.init(item: .signature, passed: signature?.succeeded ?? false,
                            detail: signature.map { $0.succeeded ? "codesign: valid, signed by Apple"
                                : layout.redact(ErrorClassifier.technicalDetail($0.combinedOutput, layout: layout, maxLines: 2)) } ?? "codesign could not be run"))
        // The startup folder cannot always be read (bless only reads some drives); the rest must all hold.
        let essential = checks.filter { $0.item != .blessed }
        let verification: ToolVerification = essential.allSatisfy(\.passed) ? (blessed ? .verified : .partiallyVerified) : .failed
        return InstallMediaResult(verification: verification, volume: root, checks: checks)
    }
}

extension SystemLayout {
    static let realDiskutil = "/usr/sbin/diskutil"
}
