import Foundation

public enum InventoryPhase: String, Sendable, CaseIterable {
    case applications, homebrew, appStore, matching, python, developerTools, fonts, colorProfiles
}

public struct InventoryProgress: Sendable, Equatable {
    public var phase: InventoryPhase
    /// 0…1 across the whole scan.
    public var fraction: Double
    public var detail: String?

    public init(phase: InventoryPhase, fraction: Double, detail: String?) {
        self.phase = phase
        self.fraction = fraction
        self.detail = detail
    }
}

public enum InventoryWarning: Equatable, Sendable {
    case homebrewNotInstalled
    case homebrewBroken(reason: String)
    case homebrewListFailed
    case masNotInstalled
    case masListFailed
    case catalogUnavailable
}

public struct InventoryResult: Sendable {
    public var manifest: Manifest
    public var fonts: [ScannedFile]
    public var colorProfiles: [ScannedFile]
    /// Python project files and application data, copied into the backup as they are.
    public var extraFiles: [ScannedFile]
    public var warnings: [InventoryWarning]

    public init(manifest: Manifest, fonts: [ScannedFile], colorProfiles: [ScannedFile], extraFiles: [ScannedFile] = [],
                warnings: [InventoryWarning] = []) {
        self.manifest = manifest
        self.fonts = fonts
        self.colorProfiles = colorProfiles
        self.extraFiles = extraFiles
        self.warnings = warnings
    }

    /// The identifier used for choosing a font or profile for the backup, e.g. `font:user/Example.otf`.
    public static func selectionID(_ record: FileRecord, kind: BackupFileKind) -> String {
        (kind == .font ? "font:" : "icc:") + record.id
    }

    /// Fonts and profiles that are not pre-selected for the backup: display profiles macOS generated
    /// for the old Mac's displays are never useful on another Mac.
    public var filesNotSelectedByDefault: Set<String> {
        Set(colorProfiles.filter { $0.record.origin == .displayGenerated }.map { Self.selectionID($0.record, kind: .colorProfile) })
    }

    /// Leaves out the fonts and profiles the user deselected and records the selection in the manifest.
    public mutating func excludeFiles(_ ids: Set<String>) {
        let fontsFound = fonts.count
        let profilesFound = colorProfiles.count
        fonts.removeAll { ids.contains(Self.selectionID($0.record, kind: .font)) }
        colorProfiles.removeAll { ids.contains(Self.selectionID($0.record, kind: .colorProfile)) }
        manifest.fonts.removeAll { ids.contains(Self.selectionID($0, kind: .font)) }
        manifest.iccProfiles.removeAll { ids.contains(Self.selectionID($0, kind: .colorProfile)) }
        manifest.backupSelection = BackupSelectionSummary(fontsFound: fontsFound, fontsSelected: fonts.count,
                                                          profilesFound: profilesFound, profilesSelected: colorProfiles.count)
    }

    /// Keeps only the chosen Python environments and their project files.
    public mutating func keepPythonEnvironments(_ ids: Set<String>, includeSettings: Bool) {
        let removed = manifest.python.environments.filter { !ids.contains($0.id) }
        let removedPaths = Set(removed.flatMap { $0.projectFiles.map(\.backupPath) })
        manifest.python.environments.removeAll { !ids.contains($0.id) }
        extraFiles.removeAll { removedPaths.contains($0.record.backupPath) }
        if !includeSettings { manifest.python.settings = [] }
    }

    /// Adds a saved copy of the chosen environments to the backup (archives created in `workFolder`).
    /// Environments that contain files that look like credentials are not copied; that is recorded.
    public mutating func preservePythonEnvironments(_ ids: Set<String>, layout: SystemLayout, runner: CommandRunning, workFolder: URL) async {
        guard !ids.isEmpty else { return }
        let keys = manifest.hardwareKeys ?? HardwareKeys.make(platformIdentifier: nil)
        manifest.hardwareKeys = keys
        for index in manifest.python.environments.indices where ids.contains(manifest.python.environments[index].id) {
            let environment = manifest.python.environments[index]
            switch (try? await PythonPreserver.preserve(environment, layout: layout, runner: runner, workFolder: workFolder, keys: keys)) {
            case .preserved(let file, let preservation)?:
                extraFiles.append(file)
                manifest.python.environments[index].preservation = preservation
            case .refused(let issue)?:
                manifest.backupIssues.append(issue)
            case nil:
                manifest.backupIssues.append(BackupIssue(path: environment.path, reason: .unreadable))
            }
        }
    }

    /// Keeps only the chosen package and version managers (by provider).
    public mutating func keepToolchains(_ providers: Set<ToolchainProviderID>) {
        manifest.toolchains.removeAll { !providers.contains($0.provider) }
    }

    /// Leaves out applications the user deselected for the backup (by `AppRecord.id`).
    public mutating func excludeApplications(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        manifest.applications.removeAll { ids.contains($0.id) }
    }

    /// Adds a folder of application data chosen by the user (replacing an earlier scan of it).
    public mutating func addApplicationData(_ folder: AppDataFolder, files: [ScannedFile], issues: [BackupIssue]) {
        removeApplicationData(id: folder.id)
        manifest.applicationData.append(folder)
        extraFiles += files
        manifest.backupIssues += issues
    }

    public mutating func removeApplicationData(id: String) {
        guard let folder = manifest.applicationData.first(where: { $0.id == id }) else { return }
        let prefix = "~/" + folder.relativePath + "/"
        manifest.applicationData.removeAll { $0.id == id }
        extraFiles.removeAll { $0.record.backupPath.hasPrefix("application-data/\(id)/") }
        manifest.backupIssues.removeAll { $0.path.hasPrefix(prefix) }
    }
}

/// Collects everything MacReplica can restore. The scan only reads; it never changes the system.
public struct InventoryService: Sendable {
    public var layout: SystemLayout
    public var runner: CommandRunning
    public var catalogProvider: CatalogProviding
    public var macOSVersion: String
    public var architecture: CPUArchitecture
    /// Extra folders to search for Python environments.
    public var pythonSearchFolders: [URL]

    public init(layout: SystemLayout, runner: CommandRunning, catalogProvider: CatalogProviding,
                macOSVersion: String = SystemInfo.macOSVersion, architecture: CPUArchitecture = SystemInfo.currentArchitecture,
                pythonSearchFolders: [URL] = []) {
        self.layout = layout
        self.runner = runner
        self.catalogProvider = catalogProvider
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.pythonSearchFolders = pythonSearchFolders
    }

    public func run(progress: @Sendable (InventoryProgress) -> Void = { _ in }) async throws -> InventoryResult {
        var warnings: [InventoryWarning] = []

        var locations: [LocationAccess] = layout.applicationFolders.map {
            LocationAccess(area: .applications, location: layout.displayPath($0), status: AccessProbe.status(of: $0))
        }

        // 1. Applications (0 – 30 %)
        let scanner = AppScanner(layout: layout)
        let bundles = scanner.bundleURLs()
        var apps: [AppRecord] = []
        var bundleByPath: [String: URL] = [:]
        for (index, bundle) in bundles.enumerated() {
            try Task.checkCancellation()
            progress(InventoryProgress(phase: .applications, fraction: 0.3 * Double(index) / Double(max(bundles.count, 1)),
                                       detail: bundle.deletingPathExtension().lastPathComponent))
            if let record = scanner.read(bundle: bundle) {
                apps.append(record)
                bundleByPath[record.path] = bundle
            }
        }

        // 2. Homebrew (30 – 45 %)
        progress(InventoryProgress(phase: .homebrew, fraction: 0.3, detail: nil))
        let homebrew = HomebrewClient(layout: layout, runner: runner)
        var snapshot: HomebrewSnapshot?
        var packages = InstalledHomebrewPackages(formulae: [], casks: [])
        var taps: [BrewTapRecord] = []
        switch await homebrew.locate() {
        case .notInstalled:
            warnings.append(.homebrewNotInstalled)
            locations.append(LocationAccess(area: .homebrew, location: "Homebrew", status: .notFound))
        case .broken(_, let reason):
            warnings.append(.homebrewBroken(reason: reason))
            locations.append(LocationAccess(area: .homebrew, location: "Homebrew", status: .unsupported))
        case .ready(let brew):
            locations.append(LocationAccess(area: .homebrew, location: layout.displayPath(brew.prefix), status: .scanned))
            snapshot = HomebrewSnapshot(version: brew.version, prefix: layout.displayPath(brew.prefix))
            do {
                packages = try await homebrew.installedPackages(brew)
                taps = (try? await homebrew.taps(brew)) ?? []
            } catch {
                warnings.append(.homebrewListFailed)
            }
        }
        Self.linkCasks(packages.casks, to: &apps)

        // Apps whose origin is still unknown may come from an installer package.
        for index in apps.indices where apps[index].source == .unknown {
            try Task.checkCancellation()
            if let bundle = bundleByPath[apps[index].path], let identifier = await packageIdentifier(for: bundle) {
                apps[index].source = .package(identifier: identifier)
            }
        }

        // 3. Mac App Store (45 – 55 %)
        progress(InventoryProgress(phase: .appStore, fraction: 0.45, detail: nil))
        let masClient = MASClient(layout: layout, runner: runner)
        var masApps: [MASAppRecord] = []
        if let mas = masClient.locate() {
            do {
                masApps = try await masClient.installedApps(mas: mas)
                locations.append(LocationAccess(area: .appStore, location: "mas", status: .scanned))
            } catch {
                warnings.append(.masListFailed)
                locations.append(LocationAccess(area: .appStore, location: "mas", status: .unsupported))
            }
        } else if apps.contains(where: { $0.source == .appStore }) {
            warnings.append(.masNotInstalled)
            locations.append(LocationAccess(area: .appStore, location: "mas", status: .notFound))
        }
        for index in apps.indices where apps[index].source == .appStore {
            var identifier: Int?
            if let bundle = bundleByPath[apps[index].path] { identifier = await masClient.appStoreID(ofBundle: bundle) }
            if identifier == nil {
                identifier = masApps.first { Matcher.normalize($0.name) == Matcher.normalize(apps[index].name) }?.appStoreID
            }
            if let identifier {
                apps[index].restoreMethod = .appStore(id: identifier)
                if let existing = masApps.firstIndex(where: { $0.appStoreID == identifier }) {
                    masApps[existing].bundleIdentifier = apps[index].bundleIdentifier
                } else {
                    masApps.append(MASAppRecord(appStoreID: identifier, name: apps[index].name,
                                                version: apps[index].version, bundleIdentifier: apps[index].bundleIdentifier))
                }
            }
        }

        // 4. Homebrew matching for everything else (55 – 70 %)
        progress(InventoryProgress(phase: .matching, fraction: 0.55, detail: nil))
        if apps.contains(where: { $0.restoreMethod == .manual && $0.source != .appStore }) {
            do {
                let matcher = Matcher(catalog: try await catalogProvider.loadCatalog())
                Self.applyMatches(matcher, to: &apps)
            } catch {
                warnings.append(.catalogUnavailable)
            }
        }

        // 5. Python (70 – 80 %)
        progress(InventoryProgress(phase: .python, fraction: 0.7, detail: nil))
        let python = PythonScanner(layout: layout, extraRoots: pythonSearchFolders).scan()
        locations.append(LocationAccess(area: .python, location: "~", status: AccessProbe.status(of: layout.homeDirectory)))
        for folder in pythonSearchFolders {
            locations.append(LocationAccess(area: .python, location: layout.displayPath(folder), status: AccessProbe.status(of: folder)))
        }
        let developer = DeveloperSettingsScanner(layout: layout).scan()
        let detectedData = AppDataProviders.detect(layout: layout)

        // Package and version managers, runtimes and global tools (files only, no tool is started).
        progress(InventoryProgress(phase: .developerTools, fraction: 0.76, detail: nil))
        let toolchains = ToolchainCatalog.scan(ToolchainContext(layout: layout, architecture: architecture))

        // 6. Fonts and color profiles (80 – 100 %)
        progress(InventoryProgress(phase: .fonts, fraction: 0.8, detail: nil))
        let files = FileScanner(layout: layout)
        let fonts = files.scan(.font)
        progress(InventoryProgress(phase: .colorProfiles, fraction: 0.92, detail: nil))
        let profiles = files.scan(.colorProfile)
        for (area, url) in [(AccessArea.userFonts, layout.userFonts), (.systemFonts, layout.systemFonts),
                            (.userColorProfiles, layout.userColorProfiles), (.systemColorProfiles, layout.systemColorProfiles)] {
            locations.append(LocationAccess(area: area, location: layout.displayPath(url), status: AccessProbe.status(of: url)))
        }

        var manifest = Manifest(
            macreplicaVersion: SystemInfo.appVersion,
            createdAt: Date(),
            macosVersion: macOSVersion,
            architecture: architecture,
            homebrew: snapshot,
            applications: apps,
            brewFormulae: packages.formulae,
            brewCasks: packages.casks,
            brewTaps: taps,
            masApps: masApps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            fonts: fonts.map(\.record),
            iccProfiles: profiles.map(\.record),
            python: python.snapshot,
            locations: locations,
            developer: developer,
            toolchains: toolchains)
        manifest.macreplicaBuild = SystemInfo.buildNumber
        // Display profile assignments (read-only); identifiers only as salted hashes.
        let displayManager = layout.displayColorManager
        let keys = HardwareKeys.make(platformIdentifier: displayManager.platformIdentifier())
        manifest.hardwareKeys = keys
        manifest.displayProfiles = DisplayProfileScanner.assignments(displays: displayManager.displays(), profiles: profiles.map(\.record),
                                                                     layout: layout, keys: keys)
        manifest.guidance = GuidanceDetector.detect(layout: layout, installedBundleIDs: Set(apps.compactMap(\.bundleIdentifier)))
        var result = InventoryResult(manifest: manifest, fonts: fonts, colorProfiles: profiles, extraFiles: python.projectFiles, warnings: warnings)
        // Known user-created data of supported apps (presets, styles, LUTs …) is suggested automatically.
        for detected in detectedData {
            if let scan = try? AppDataScanner(layout: layout).scan(detected.folder, profile: detected.profile, onlyFiles: detected.files,
                                                                     excluding: detected.excluding),
               !scan.files.isEmpty {
                result.addApplicationData(scan.folder, files: scan.files, issues: scan.issues)
            } else {
                result.manifest.locations.append(LocationAccess(area: .applicationData, location: layout.displayPath(detected.folder),
                                                                status: AccessProbe.status(of: detected.folder)))
            }
        }
        progress(InventoryProgress(phase: .colorProfiles, fraction: 1, detail: nil))
        return result
    }

    /// Marks apps that an installed cask provides.
    static func linkCasks(_ casks: [BrewCaskRecord], to apps: inout [AppRecord]) {
        for cask in casks {
            for artifact in cask.appArtifacts {
                for index in apps.indices where apps[index].bundleFileName.caseInsensitiveCompare(artifact) == .orderedSame {
                    apps[index].source = .homebrewCask(token: cask.token)
                    apps[index].restoreMethod = .homebrewCask(token: cask.token)
                    // The cask token names the channel exactly (`firefox@nightly`); restoring the same cask reproduces it.
                    if let channel = ChannelDetector.channel(caskToken: cask.token) {
                        apps[index].channel = channel
                        apps[index].channelEvidence = .homebrewCask
                    }
                }
            }
        }
    }

    static func applyMatches(_ matcher: Matcher, to apps: inout [AppRecord]) {
        for index in apps.indices where apps[index].restoreMethod == .manual && apps[index].source != .appStore {
            switch matcher.match(apps[index]) {
            case .unique(let candidate):
                apps[index].restoreMethod = candidate.restoreMethod
                apps[index].homepage = candidate.homepage
                apps[index].candidates = []
            case .needsDecision(let candidates):
                apps[index].candidates = candidates
                let homepages = Set(candidates.compactMap(\.homepage))
                if homepages.count == 1, let homepage = homepages.first, Self.isWebURL(homepage) {
                    apps[index].homepage = homepage
                    apps[index].restoreMethod = .officialDownload(url: homepage)
                }
            case .none:
                break
            }
        }
    }

    static func isWebURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && url.host != nil
    }

    /// The installer package that placed a bundle, via `pkgutil --file-info`.
    func packageIdentifier(for bundle: URL) async -> String? {
        let result = try? await runner.run(Command(
            executable: layout.pkgutil, arguments: ["--file-info", bundle.path],
            environment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil), timeout: 30))
        guard let result, result.succeeded else { return nil }
        return Self.parsePkgutilFileInfo(result.stdout)
    }

    public static func parsePkgutilFileInfo(_ output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pkgid:") {
                let identifier = trimmed.dropFirst("pkgid:".count).trimmingCharacters(in: .whitespaces)
                if !identifier.isEmpty { return identifier }
            }
        }
        return nil
    }
}
