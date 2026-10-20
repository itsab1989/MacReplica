import Foundation

/// What a macOS installer app in Applications really is, read from the app itself – nothing assumed from its name.
public struct InstallerAppReport: Equatable, Sendable {
    public var app: URL
    /// `CFBundleDisplayName` (or the folder name): "Install macOS Sonoma".
    public var displayName: String
    /// The installer app's own version (not the macOS version): "19.8.9".
    public var appVersion: String?
    /// The macOS version and build inside, when the installer says so.
    public var macOSVersion: String?
    public var build: String?
    public var sizeBytes: Int64
    /// `Contents/Resources/createinstallmedia`, if the installer has one (Lion and Mountain Lion do not).
    public var createInstallMedia: URL?
    /// Options the tool itself lists.
    public var supportsNoInteraction: Bool
    public var needsApplicationPath: Bool
    /// The tool's processors; an Intel-only tool needs Rosetta on Apple silicon.
    public var toolArchitectures: [CPUArchitecture]
    /// Apple's signature on the app and on its `createinstallmedia` (see `InstallerInspector.appleRequirement`).
    public var signedByApple: Bool
    public var signatureDetail: String
    /// Big Sur and later keep the installer in `SharedSupport/SharedSupport.dmg`; older ones in `InstallESD.dmg`.
    public var hasInstallerPayload: Bool
    /// Why the tool could not be asked for its options (it did not start, did not answer in time, or failed); nil if
    /// it answered.
    public var toolUsageProblem: String?

    public init(app: URL, displayName: String, appVersion: String? = nil, macOSVersion: String? = nil, build: String? = nil,
                sizeBytes: Int64 = 0, createInstallMedia: URL? = nil, supportsNoInteraction: Bool = false, needsApplicationPath: Bool = false,
                toolArchitectures: [CPUArchitecture] = [], signedByApple: Bool = false, signatureDetail: String = "", hasInstallerPayload: Bool = false) {
        self.app = app
        self.displayName = displayName
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.build = build
        self.sizeBytes = sizeBytes
        self.createInstallMedia = createInstallMedia
        self.supportsNoInteraction = supportsNoInteraction
        self.needsApplicationPath = needsApplicationPath
        self.toolArchitectures = toolArchitectures
        self.signedByApple = signedByApple
        self.signatureDetail = signatureDetail
        self.hasInstallerPayload = hasInstallerPayload
    }

    /// Space the drive needs: the installer plus room for the startup files `createinstallmedia` adds.
    public var requiredBytes: Int64 { sizeBytes + 2 * 1_073_741_824 }
}

/// Why an installer cannot be used for a bootable drive.
public enum InstallerAppProblem: Equatable, Sendable {
    case notFound
    case notSignedByApple(String)
    case noCreateInstallMedia
    /// The tool cannot run without asking a question MacReplica cannot answer.
    case toolNeedsInteraction
    /// The tool could not be asked which options it has (it did not start, did not answer, or failed).
    case toolDidNotAnswer(String)
    case needsRosetta
    case payloadMissing
    case incomplete(String)
}

public struct InstallerInspector: Sendable {
    public var layout: SystemLayout
    public var runner: CommandRunning
    public var environment: ToolEnvironment
    /// Whether Rosetta is installed (an Intel-only `createinstallmedia` on Apple silicon needs it).
    public var hasRosetta: Bool

    public init(layout: SystemLayout, runner: CommandRunning, environment: ToolEnvironment, hasRosetta: Bool) {
        self.layout = layout
        self.runner = runner
        self.environment = environment
        self.hasRosetta = hasRosetta
    }

    /// Signed by Apple: Apple's own signing (`anchor apple`, today's installers, e.g. 14.8.9: “Software Signing”) or a
    /// certificate Apple issued to Apple Inc. under its root – older installers from the App Store are signed that way
    /// (OS X Mountain Lion: “3rd Party Mac Developer Application: Apple Inc.”). Other developers' certificates never
    /// carry Apple Inc. as their organisation.
    public static let appleRequirement = #"anchor apple or (anchor apple generic and certificate leaf[subject.O] = "Apple Inc.")"#

    /// `Install *.app` directly in the Applications folders.
    public func installedInstallers() -> [URL] {
        let fm = FileManager.default
        return layout.applicationFolders.flatMap { folder in
            ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasPrefix("Install ") && $0.hasSuffix(".app") }
                .map { folder.appendingPathComponent($0) }
        }
        .filter { fm.fileExists(atPath: $0.appendingPathComponent("Contents/Info.plist").path) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The installer for a release: Apple's app name ("Install " + its name) in an Applications folder.
    public func installer(for release: MacOSRelease) -> URL? {
        installedInstallers().first { $0.lastPathComponent == release.installerAppName }
    }

    public func inspect(_ app: URL) async -> InstallerAppReport {
        let fm = FileManager.default
        let contents = app.appendingPathComponent("Contents")
        let info = Self.plist(contents.appendingPathComponent("Info.plist")) ?? [:]
        var report = InstallerAppReport(app: app, displayName: (info["CFBundleDisplayName"] as? String) ?? app.deletingPathExtension().lastPathComponent,
                                        appVersion: info["CFBundleShortVersionString"] as? String)
        report.sizeBytes = Self.allocatedSize(of: app)
        let tool = contents.appendingPathComponent("Resources/createinstallmedia")
        var toolSigned = false
        var toolDetail = ""
        if fm.isExecutableFile(atPath: tool.path) {
            report.createInstallMedia = tool
            report.toolArchitectures = MachO.architectures(ofFile: tool)
            // The tool runs as root later, so it must be Apple's own, unchanged.
            let check = try? await runner.run(Command(executable: layout.codesign, arguments: ["--verify", "--strict", "-R=" + Self.appleRequirement, tool.path],
                                                      timeout: 120))
            toolSigned = check?.succeeded ?? false
            toolDetail = check.map { layout.redact(ErrorClassifier.technicalDetail($0.combinedOutput, layout: layout, maxLines: 2)) } ?? "codesign could not be run"
            if toolSigned {
                // Without arguments the tool only prints its options (checked with macOS 14's tool: exit 0, no change).
                let (usage, problem) = await self.usage(of: tool)
                report.toolUsageProblem = problem
                report.supportsNoInteraction = usage.contains("--nointeraction")
                // El Capitan and Sierra need the installer named again (Apple, support.apple.com/101578): their
                // tools list `--applicationpath` but not `--downloadassets`, which came with Mojave. High Sierra's
                // tool is in that group too and takes the option.
                report.needsApplicationPath = usage.contains("--applicationpath") && !usage.contains("--downloadassets")
            }
        }
        let shared = contents.appendingPathComponent("SharedSupport")
        report.hasInstallerPayload = fm.fileExists(atPath: shared.appendingPathComponent("SharedSupport.dmg").path)
            || fm.fileExists(atPath: shared.appendingPathComponent("InstallESD.dmg").path)
        // Catalina and earlier name the version in InstallInfo.plist.
        if let installInfo = Self.plist(shared.appendingPathComponent("InstallInfo.plist")),
           let image = installInfo["System Image Info"] as? [String: Any] {
            report.macOSVersion = image["version"] as? String
        }
        if report.macOSVersion == nil, fm.fileExists(atPath: shared.appendingPathComponent("SharedSupport.dmg").path) {
            let (version, build) = await sharedSupportVersion(shared.appendingPathComponent("SharedSupport.dmg"))
            report.macOSVersion = version
            report.build = build
        }
        // Apple's installer apps keep an old form of resource rules that `--strict` rejects ("resource envelope is
        // obsolete", seen with macOS 14's installer); the seal and Apple's signature are still checked without it.
        let signature = try? await runner.run(Command(executable: layout.codesign, arguments: ["--verify", "--no-strict", "-R=" + Self.appleRequirement, app.path],
                                                      timeout: 900))
        let appSigned = signature?.succeeded ?? false
        report.signedByApple = appSigned && (report.createInstallMedia == nil || toolSigned)
        if !appSigned {
            report.signatureDetail = signature.map { layout.redact(ErrorClassifier.technicalDetail($0.combinedOutput, layout: layout, maxLines: 3)) }
                ?? "codesign could not be run"
        } else if report.createInstallMedia != nil, !toolSigned {
            report.signatureDetail = "createinstallmedia: " + toolDetail
        } else {
            report.signatureDetail = "codesign: valid, signed by Apple"
        }
        return report
    }

    /// Reads the macOS version and build from the installer's `SharedSupport.dmg` (attached read-only, hidden, and
    /// detached again).
    func sharedSupportVersion(_ image: URL) async -> (String?, String?) {
        let environment = layout.processEnvironment(homebrewPrefix: nil, askpass: nil)
        guard let attach = try? await DownloadInstaller.attachWithRetry(runner: runner, hdiutil: layout.hdiutil, environment: environment,
                                                                        arguments: ["attach", "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-plist", image.path]),
              attach.succeeded, let mount = DownloadInstaller.mountPoint(fromAttachOutput: attach.stdout) else { return (nil, nil) }
        let xml = mount.appendingPathComponent("com_apple_MobileAsset_MacSoftwareUpdate/com_apple_MobileAsset_MacSoftwareUpdate.xml")
        let asset = (Self.plist(xml)?["Assets"] as? [[String: Any]])?.first
        await DownloadInstaller.detachAttachments(of: image.path, runner: runner, hdiutil: layout.hdiutil, environment: environment)
        return (asset?["OSVersion"] as? String, asset?["Build"] as? String)
    }

    /// Whether the installer can make a bootable drive on this Mac, and if not, why.
    public func problems(of report: InstallerAppReport) -> [InstallerAppProblem] {
        var problems: [InstallerAppProblem] = []
        if !report.signedByApple { problems.append(.notSignedByApple(report.signatureDetail)) }
        guard report.createInstallMedia != nil else { return problems + [.noCreateInstallMedia] }
        if !report.supportsNoInteraction {
            problems.append(report.toolUsageProblem.map(InstallerAppProblem.toolDidNotAnswer) ?? .toolNeedsInteraction)
        }
        // Only a Mach-O tool built for Intel alone needs Rosetta; a script or an unreadable header claims nothing.
        if environment.architecture == .arm64, !report.toolArchitectures.isEmpty, !report.toolArchitectures.contains(.arm64), !hasRosetta {
            problems.append(.needsRosetta)
        }
        if !report.hasInstallerPayload { problems.append(.payloadMissing) }
        return problems
    }

    static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    public static func allocatedSize(of folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// What the tool prints without arguments: its options. Run as the user; it changes nothing without root and
    /// a volume.
    func usage(of tool: URL) async -> (String, String?) {
        let usageRunner = (runner as? CommandPolicyExtending)?.allowing([tool.path]) ?? runner
        do {
            let result = try await usageRunner.run(Command(executable: tool.path, arguments: [],
                                                           environment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil), timeout: 120))
            if result.timedOut { return (result.combinedOutput, "no answer within 120 s") }
            if result.combinedOutput.contains("--volume") { return (result.combinedOutput, nil) }
            return (result.combinedOutput, layout.redact("exit \(result.exitCode): " + ErrorClassifier.technicalDetail(result.combinedOutput, layout: layout, maxLines: 2)))
        } catch {
            // Starting it failed (e.g. macOS refused): never read as “no such option”.
            return ("", layout.redact(String(describing: error)))
        }
    }
}
