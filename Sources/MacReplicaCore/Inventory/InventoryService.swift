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
    /// App Store apps that could not be identified (Spotlight had no App Store ID) and `mas` is not
    /// installed to look them up. `homebrewAvailable`: MacReplica can offer to install `mas`.
    case masNeeded(unidentifiedApps: Int, homebrewAvailable: Bool)
    case masListFailed
    case catalogUnavailable
    /// The Launchpad arrangement could not be read; the backup has everything else.
    case launchpadUnreadable
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
        let removed = Set(manifest.applications.filter { ids.contains($0.id) }.compactMap(\.bundleIdentifier))
        manifest.applications.removeAll { ids.contains($0.id) }
        // They leave the Launchpad layout too (unless another copy of the app stays in the backup).
        let kept = Set(manifest.applications.compactMap(\.bundleIdentifier))
        manifest.launchpadLayout = manifest.launchpadLayout?.removing(removed.subtracting(kept))
    }

    /// Adds a folder of application data chosen by the user (replacing an earlier scan of it).
    public mutating func addApplicationData(_ folder: AppDataFolder, files: [ScannedFile], issues: [BackupIssue]) {
        removeApplicationData(id: folder.id)
        manifest.applicationData.append(folder)
        extraFiles += files
        manifest.backupIssues += issues
    }

    /// Attaches the user's own installers to an app (replacing earlier ones). Files marked for inclusion are
    /// copied into the backup (`installers/<id>/<file>`) and checked like every other file.
    public mutating func attachInstallers(_ installers: [(archive: InstallerArchive, file: URL, include: Bool)], toApp appID: String) {
        guard let index = manifest.applications.firstIndex(where: { $0.id == appID }) else { return }
        for old in manifest.applications[index].ownInstallers ?? [] where old.includedPath != nil {
            extraFiles.removeAll { $0.record.backupPath == old.includedPath }
        }
        var archives: [InstallerArchive] = []
        for (archive, file, include) in installers {
            var entry = archive
            entry.includedPath = nil
            if include, PathSafety.isSafeRelativePath(archive.fileName), !archive.fileName.contains("/") {
                let path = "installers/\(archive.id)/\(archive.fileName)"
                entry.includedPath = path
                let record = FileRecord(fileName: archive.fileName, domain: .user, relativePath: archive.fileName, originalPath: archive.originalPath,
                                        backupPath: path, sha256: archive.sha256, size: archive.size)
                if !extraFiles.contains(where: { $0.record.backupPath == path }) { extraFiles.append(ScannedFile(url: file, record: record)) }
            }
            archives.append(entry)
        }
        manifest.applications[index].ownInstallers = archives.isEmpty ? nil : archives
    }

    public mutating func removeApplicationData(id: String) {
        guard let folder = manifest.applicationData.first(where: { $0.id == id }) else { return }
        let prefix = folder.displayPath + "/"
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
        apps = Self.mergeCopies(apps, applicationFolders: layout.applicationFolders.map { layout.displayPath($0) })

        // 2. Homebrew (30 – 45 %)
        progress(InventoryProgress(phase: .homebrew, fraction: 0.3, detail: nil))
        let homebrew = HomebrewClient(layout: layout, runner: runner)
        var snapshot: HomebrewSnapshot?
        var packages = InstalledHomebrewPackages(formulae: [], casks: [])
        var taps: [BrewTapRecord] = []
        var tapCasks: [CaskInfo] = []
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
                // Casks of the third-party taps on this Mac, so apps installed from a vendor's DMG are matched too.
                tapCasks = await homebrew.tapCasks(brew, tokens: taps.flatMap { $0.caskTokens ?? [] })
            } catch {
                warnings.append(.homebrewListFailed)
            }
        }
        Self.linkCasks(packages.casks, to: &apps)
        Self.linkCompanions(&apps, casks: packages.casks)

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
        }
        // App Store IDs come from Spotlight (`kMDItemAppStoreAdamID`); `mas` is only needed for apps Spotlight
        // has no ID for. Without it, those apps are reported; everything else needs no warning.
        var unidentifiedAppStoreApps = 0
        for index in apps.indices where apps[index].source == .appStore {
            var identifier: Int?
            if let bundle = bundleByPath[apps[index].path] { identifier = await masClient.appStoreID(ofBundle: bundle) }
            if identifier == nil {
                identifier = masApps.first { Matcher.normalize($0.name) == Matcher.normalize(apps[index].name) }?.appStoreID
            }
            if identifier == nil { unidentifiedAppStoreApps += 1 }
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

        if masClient.locate() == nil, unidentifiedAppStoreApps > 0 {
            let homebrew = await HomebrewClient(layout: layout, runner: runner).locate().installation != nil
            warnings.append(.masNeeded(unidentifiedApps: unidentifiedAppStoreApps, homebrewAvailable: homebrew))
            locations.append(LocationAccess(area: .appStore, location: "mas", status: .notFound))
        }

        // 4. Homebrew matching for everything else (55 – 70 %)
        progress(InventoryProgress(phase: .matching, fraction: 0.55, detail: nil))
        if apps.contains(where: { $0.restoreMethod == .manual && $0.source != .appStore }) {
            do {
                var catalog = try await catalogProvider.loadCatalog()
                catalog.casks += tapCasks
                let matcher = Matcher(catalog: catalog)
                Self.applyMatches(matcher, to: &apps)
            } catch {
                warnings.append(.catalogUnavailable)
                if !tapCasks.isEmpty { Self.applyMatches(Matcher(catalog: CaskCatalog(casks: tapCasks)), to: &apps) }
            }
        }
        Self.applyVendorTaps(to: &apps, taps: &taps)

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
        if apps.contains(where: OfficeActivation.isOfficeApp) { manifest.officeActivation = OfficeActivation.detect(layout: layout) }
        // Display profile assignments (read-only); identifiers only as salted hashes.
        let displayManager = layout.displayColorManager
        let keys = HardwareKeys.make(platformIdentifier: displayManager.platformIdentifier())
        manifest.hardwareKeys = keys
        manifest.displayProfiles = DisplayProfileScanner.assignments(displays: displayManager.displays(), profiles: profiles.map(\.record),
                                                                     layout: layout, keys: keys)
        // The Launchpad arrangement (read from a copy of the Dock's database; macOS 13–15 only).
        if LaunchpadLayout.isSupported(macOSVersion: macOSVersion), let store = layout.launchpadStore {
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("macreplica-launchpad-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                let recorded = try store.read(macOSVersion: macOSVersion, work: work)
                if recorded.appCount > 0 { manifest.launchpadLayout = recorded }
            } catch LaunchpadError.databaseMissing {
            } catch {
                warnings.append(.launchpadUnreadable)
            }
        }
        manifest.guidance = GuidanceDetector.detect(layout: layout, installedBundleIDs: Set(apps.compactMap(\.bundleIdentifier)),
                                                    installedAppNames: Set(apps.map(\.name)))
        var result = InventoryResult(manifest: manifest, fonts: fonts, colorProfiles: profiles, extraFiles: python.projectFiles, warnings: warnings)
        // Known user-created data of supported apps (presets, styles, LUTs …) is suggested automatically.
        for var detected in detectedData {
            if detected.profile.notForOlderApp {
                let ids = Set(detected.profile.bundleIdentifiers.map { $0.lowercased() })
                detected.profile.sourceAppVersion = apps.first { $0.bundleIdentifier.map { ids.contains($0.lowercased()) } ?? false }?.version
            }
            var shipped: Set<String> = []
            if let package = detected.shippedByPackage { shipped = await shippedFiles(package: package, below: detected.folder) }
            if let scan = try? AppDataScanner(layout: layout).scan(detected.folder, profile: detected.profile, onlyFiles: detected.files,
                                                                     excluding: detected.excluding, scope: detected.scope, shipped: shipped,
                                                            rewritesHomeFolder: detected.rewritesHomeFolder, allowProviderExceptions: true),
               !scan.files.isEmpty {
                result.addApplicationData(scan.folder, files: scan.files, issues: scan.issues)
            } else {
                result.manifest.locations.append(LocationAccess(area: .applicationData, location: layout.displayPath(detected.folder),
                                                                status: AccessProbe.status(of: detected.folder)))
            }
        }
        // Password databases KeePassXC remembers are listed (never included by themselves), so nobody erases the old Mac
        // believing they are in the backup.
        for database in result.rememberedPasswordDatabases(layout: layout) {
            result.manifest.backupIssues.append(BackupIssue(path: layout.displayPath(database), reason: .refusedSensitive, detail: .rememberedByApp,
                                                            sensitive: SensitiveFileClassifier.classify(database)))
        }
        progress(InventoryProgress(phase: .colorProfiles, fraction: 1, detail: nil))
        return result
    }

    /// One record per app: copies with the same bundle identifier (e.g. Zoom in `/Applications` and in
    /// `~/Applications`, or a copy left in a subfolder) are merged. The copy that is kept is the one in the
    /// first application folder (`/Applications`), then the newest version; the others are listed in
    /// `otherCopies`. Apps without a bundle identifier are never merged.
    static func mergeCopies(_ apps: [AppRecord], applicationFolders: [String]) -> [AppRecord] {
        func folderRank(_ app: AppRecord) -> Int {
            applicationFolders.firstIndex { app.path.hasPrefix($0 + "/") } ?? applicationFolders.count
        }
        var result: [AppRecord] = []
        var indexByIdentifier: [String: Int] = [:]
        for app in apps {
            guard let key = app.bundleIdentifier?.lowercased(), !key.isEmpty else { result.append(app); continue }
            guard let index = indexByIdentifier[key] else {
                indexByIdentifier[key] = result.count
                result.append(app)
                continue
            }
            var kept = result[index], other = app
            let otherIsBetter = folderRank(other) < folderRank(kept)
                || (folderRank(other) == folderRank(kept)
                    && VersionComparison.compare(other.version ?? "0", kept.version ?? "0") == .orderedDescending)
            if otherIsBetter { swap(&kept, &other) }
            kept.otherCopies = (kept.otherCopies ?? []) + (other.otherCopies ?? []) + [AppRecord.OtherCopy(path: other.path, version: other.version)]
            other.otherCopies = nil
            result[index] = kept
        }
        return result
    }

    /// Apps that come with another app: in the same folder of an application folder (a suite folder such as
    /// `/Applications/DisplayCAL/`) with a bundle identifier that extends the main app's (`net.displaycal.DisplayCAL` →
    /// `net.displaycal.DisplayCAL-3DLUT-maker`), or installed by the same cask as the cask's first app. Apps that are
    /// merely from the same developer are not grouped.
    static func linkCompanions(_ apps: inout [AppRecord], casks: [BrewCaskRecord]) {
        var bySuite: [String: [Int]] = [:]
        for index in apps.indices { if let folder = apps[index].suiteFolderName { bySuite[folder, default: []].append(index) } }
        for (_, members) in bySuite where members.count > 1 {
            let identified = members.filter { apps[$0].bundleIdentifier != nil }
            guard let main = identified.first(where: { candidate in
                let prefix = apps[candidate].bundleIdentifier!.lowercased()
                return identified.contains { $0 != candidate && apps[$0].bundleIdentifier!.lowercased().hasPrefix(prefix) }
            }) else { continue }
            let prefix = apps[main].bundleIdentifier!.lowercased()
            for member in identified where member != main && apps[member].bundleIdentifier!.lowercased().hasPrefix(prefix) {
                apps[member].companionOf = apps[main].id
            }
        }
        for cask in casks where cask.appArtifacts.count > 1 {
            guard let main = apps.firstIndex(where: { $0.bundleFileName.caseInsensitiveCompare(cask.appArtifacts[0]) == .orderedSame }) else { continue }
            for artifact in cask.appArtifacts.dropFirst() {
                for index in apps.indices where index != main && apps[index].bundleFileName.caseInsensitiveCompare(artifact) == .orderedSame
                    && apps[index].companionOf == nil {
                    apps[index].companionOf = apps[main].id
                }
            }
        }
    }

    /// Marks apps that an installed cask provides.
    static func linkCasks(_ casks: [BrewCaskRecord], to apps: inout [AppRecord]) {
        for cask in casks {
            for artifact in cask.appArtifacts {
                for index in apps.indices where apps[index].bundleFileName.caseInsensitiveCompare(artifact) == .orderedSame {
                    apps[index].source = .homebrewCask(token: cask.token)
                    // A cask Homebrew disabled or removed cannot install the app again: the app gets the official
                    // download route instead, with the reason (e.g. Cakebrew, removed from Homebrew in 2025).
                    guard cask.isInstallable else {
                        apps[index].homebrewNote = cask.availability.map { HomebrewNote(token: cask.token, availability: $0) }
                        continue
                    }
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
        for index in apps.indices where apps[index].restoreMethod == .manual && apps[index].source != .appStore && apps[index].companionOf == nil {
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
                // Homebrew knows the app, but its cask was disabled: say why it is not used.
                if apps[index].homebrewNote == nil, let cask = matcher.disabledCask(for: apps[index]) {
                    apps[index].homebrewNote = HomebrewNote(token: cask.token, availability: CaskAvailability(state: .disabled, reason: cask.disableReason,
                                                                                                             date: cask.disableDate))
                    if let homepage = cask.homepage, Self.isWebURL(homepage) {
                        apps[index].homepage = apps[index].homepage ?? homepage
                    }
                }
            }
        }
    }

    /// Apps whose developer documents their own Homebrew tap (and that no other package matched): restored with that
    /// tap's cask, in the same channel (stable or beta) as on this Mac. The tap is recorded so the user can allow it.
    static func applyVendorTaps(to apps: inout [AppRecord], taps: inout [BrewTapRecord]) {
        for index in apps.indices where apps[index].source != .appStore {
            guard let vendor = VendorTaps.tap(for: apps[index]) else { continue }
            if case .homebrewCask = apps[index].restoreMethod { continue }
            let token = vendor.fullToken(for: apps[index].channel?.isPrerelease == true ? .beta : .stable)
            apps[index].restoreMethod = .homebrewCask(token: token)
            apps[index].candidates = []
            if let tapIndex = taps.firstIndex(where: { $0.name.lowercased() == vendor.tap }) {
                taps[tapIndex].suggestedFor = (taps[tapIndex].suggestedFor ?? []) + [apps[index].name]
            } else {
                var record = BrewTapRecord(name: vendor.tap, remote: vendor.remote)
                record.suggestedFor = [apps[index].name]
                taps.append(record)
            }
        }
    }

    static func isWebURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "https" || scheme == "http") && url.host != nil
    }

    /// Files an installer package placed below `folder` (paths relative to it), from its receipt via
    /// `pkgutil --files`. Empty if the package is not installed or the receipt cannot be read.
    func shippedFiles(package: String, below folder: URL) async -> Set<String> {
        await Self.shippedFiles(package: package, below: folder, layout: layout, runner: runner)
    }

    public static func shippedFiles(package: String, below folder: URL, layout: SystemLayout, runner: CommandRunning) async -> Set<String> {
        guard package.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$"#, options: .regularExpression) != nil,
              let result = try? await runner.run(Command(executable: layout.pkgutil, arguments: ["--files", package],
                                                         environment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil), timeout: 60)),
              result.succeeded else { return [] }
        return receiptPaths(result.stdout, below: folder, root: layout.simulationRoot)
    }

    /// Receipt paths are relative to `/` (or the simulation root standing in for it).
    static func receiptPaths(_ output: String, below folder: URL, root: URL?) -> Set<String> {
        var prefix = folder.standardizedFileURL.path
        if let root = root?.standardizedFileURL.path, prefix.hasPrefix(root + "/") { prefix = String(prefix.dropFirst(root.count)) }
        prefix = String(prefix.drop { $0 == "/" }) + "/"
        return Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
        })
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

/// Files left out because they look like secrets, included again at the user's explicit request (and left out again).
extension InventoryResult {
    public enum IncludeOnRequestError: Error, Equatable, Sendable {
        /// Keychains and browser data are never copied.
        case notAllowed
        /// The file is no longer there or cannot be read.
        case unreadable
        /// The file is not in a folder MacReplica may back up (outside the home folder, or in `~/Library` outside a provider folder).
        case outsideSelectedFolders
    }

    /// Includes a file that was left out as sensitive, exactly as it is (an encrypted database stays encrypted).
    /// The file is added to the folder it was found in; a file outside the chosen folders (e.g. a KeePass database
    /// KeePassXC remembers) is added as one of "Your own folders" with only this file.
    public mutating func includeOnRequest(_ path: String, layout: SystemLayout) throws {
        let url = layout.resolve(displayPath: path)
        guard let classification = SensitiveFileClassifier.classify(url) else { throw IncludeOnRequestError.unreadable }
        guard classification.kind.canBeIncludedOnRequest else { throw IncludeOnRequestError.notAllowed }
        guard FileManager.default.isReadableFile(atPath: url.path),
              let sha = try? Hashing.sha256Hex(ofFile: url),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { throw IncludeOnRequestError.unreadable }
        if let index = manifest.applicationData.indices
            .filter({ path.hasPrefix(manifest.applicationData[$0].displayPath + "/") })
            .max(by: { manifest.applicationData[$0].displayPath.count < manifest.applicationData[$1].displayPath.count }) {
            let folder = manifest.applicationData[index]
            let relative = String(path.dropFirst(folder.displayPath.count + 1))
            guard PathSafety.isSafeRelativePath(relative), !folder.files.contains(where: { $0.relativePath == relative }) else { return }
            var record = FileRecord(fileName: url.lastPathComponent, domain: folder.effectiveScope == .home ? .user : .system, relativePath: relative,
                                    originalPath: path, backupPath: "application-data/\(folder.id)/\(relative)", sha256: sha,
                                    size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate)
            record.metadata[AppDataScanner.includedOnRequestKey] = classification.kind.rawValue
            manifest.applicationData[index].files.append(record)
            extraFiles.append(ScannedFile(url: url, record: record))
            manifest.backupIssues.removeAll { $0.path == path && $0.reason == .refusedSensitive }
            return
        }
        let parent = url.deletingLastPathComponent()
        guard let scan = try? AppDataScanner(layout: layout).scanPersonal(parent, onlyFiles: [url.lastPathComponent],
                                                                          includeSensitive: [url.lastPathComponent]) else {
            throw IncludeOnRequestError.outsideSelectedFolders
        }
        // A folder that already holds other files of the user keeps them; this adds only the one file.
        addApplicationData(scan.folder, files: scan.files, issues: [])
        manifest.backupIssues.removeAll { $0.path == path && $0.reason == .refusedSensitive }
    }

    /// Leaves a file out again that was included on request; it is listed as left out (sensitive) as before.
    public mutating func excludeAgain(_ path: String, layout: SystemLayout) {
        for index in manifest.applicationData.indices {
            guard let record = manifest.applicationData[index].files.first(where: { $0.originalPath == path }),
                  record.metadata[AppDataScanner.includedOnRequestKey] != nil else { continue }
            manifest.applicationData[index].files.removeAll { $0.originalPath == path }
            extraFiles.removeAll { $0.record.backupPath == record.backupPath }
            let classification = SensitiveFileClassifier.classify(layout.resolve(displayPath: path))
            manifest.backupIssues.append(BackupIssue(path: path, reason: .refusedSensitive, sensitive: classification))
        }
        // A folder that only existed for this file is removed.
        let empty = manifest.applicationData.filter { $0.isPersonal && $0.files.isEmpty }.map(\.id)
        for id in empty { removeApplicationData(id: id) }
    }

    /// KeePass databases KeePassXC remembers that are neither in the backup nor already listed as left out: offered
    /// to the user, never included by themselves.
    public func rememberedPasswordDatabases(layout: SystemLayout) -> [URL] {
        let listed = Set(manifest.backupIssues.map(\.path))
        let included = Set(manifest.applicationData.flatMap(\.files).map(\.originalPath))
        return KeePassXCLocations.rememberedDatabases(layout: layout).filter {
            let path = layout.displayPath($0)
            return !listed.contains(path) && !included.contains(path)
        }
    }
}
