import Foundation

/// What the user decides while MacReplica waits for a guided step.
public enum GuidedDecision: Sendable, Equatable {
    /// "Done" – check again.
    case checkAgain
    /// Skip this app for good.
    case skip
    /// Do it later; the app stays open in the restore.
    case later
    /// Stop the installation that is in progress.
    case cancel
    /// The user pointed at the installed app (installed elsewhere or under another name). `confirmed`: the user
    /// agreed to count it although its name and identifier differ from the backup's. `copiedFrom`: it was outside
    /// Applications and was copied or `moved` there first (from this place).
    case chosen(URL, confirmed: Bool, copiedFrom: URL? = nil, moved: Bool = false)
}

/// What MacReplica asks the app (the user interface) to do during a guided installation.
public protocol GuidedInstallInteraction: Sendable {
    /// Opens a verified installer package in Apple's Installer, where the user completes it.
    func openPackage(_ url: URL) async
    /// Shows a file in Finder (e.g. a disk image whose license the user has to accept).
    func openInFinder(_ url: URL) async
    /// Opens the vendor's website or the App Store page.
    func open(_ url: URL) async
    /// Waits for the user after a step they have to finish themselves.
    func waitForUser(itemID: String, step: GuidedStep) async -> GuidedDecision
    /// The same, after "Done" found nothing (`notFound`), so the user learns why the step is asked again.
    func waitForUser(itemID: String, step: GuidedStep, notFound: Bool) async -> GuidedDecision
}

extension GuidedInstallInteraction {
    public func waitForUser(itemID: String, step: GuidedStep, notFound: Bool) async -> GuidedDecision {
        await waitForUser(itemID: itemID, step: step)
    }
}

/// The step the user is asked to complete.
public enum GuidedStep: Equatable, Sendable {
    case finishInstaller
    case installFromDiskImage
    case installFromWebsite
    case installFromAppStore
    /// The app of the old Mac is no longer in the App Store; it shows a search for this name.
    case searchAppStore(String)
    /// No official source is known: the user installs the app the way they got it originally.
    case installYourself
    /// A further package of the user's own installers (e.g. an activation package) is open in Installer.
    case finishAdditionalPackage(String)
    case runCommand(String)
}

/// Where an app is in the guided installation.
public enum GuidedInstallState: Equatable, Sendable {
    case notStarted
    case downloading
    case verifying
    case installing
    case waitingForUser(GuidedStep)
    case finished(ItemOutcome)
}

/// Downloads, verifies and installs applications that have no automatic installation, one after another
/// or individually, and reports each result as a restore outcome so an interrupted session can continue.
public actor GuidedInstallation {
    public typealias StateObserver = @Sendable (String, GuidedInstallState) -> Void

    private let installer: DownloadInstaller
    private let queue: DownloadQueue
    private let log: LogStore?
    private let observer: StateObserver
    private var states: [String: GuidedInstallState] = [:]

    public init(installer: DownloadInstaller, queue: DownloadQueue, log: LogStore? = nil, observer: @escaping StateObserver = { _, _ in }) {
        self.installer = installer
        self.queue = queue
        self.log = log
        self.observer = observer
    }

    public func state(_ itemID: String) -> GuidedInstallState { states[itemID] ?? .notStarted }

    private func set(_ itemID: String, _ state: GuidedInstallState) {
        states[itemID] = state
        observer(itemID, state)
    }

    /// Installs the apps one after another with the chosen offers. Downloads start in the background
    /// right away, so the next app is usually ready when the previous one is done.
    public func runSequence(_ entries: [(item: RestoreItem, offer: DownloadOffer?)], interaction: GuidedInstallInteraction,
                            isInstalled: @escaping @Sendable (RestoreItem) -> String??,
                            record: @escaping @Sendable (String, ItemResult) async -> Void) async {
        for entry in entries where entry.offer?.isDownloadable == true && isInstalled(entry.item) == nil {
            await queue.enqueue(entry.offer!)
        }
        for entry in entries {
            if Task.isCancelled { break }
            let result = await install(entry.item, offer: entry.offer, interaction: interaction, isInstalled: isInstalled)
            await record(entry.item.id, result)
            if case .skipped(.cancelledByUser) = result.outcome {
                // Cancelling one installation stops the sequence; the rest stays open for later.
                break
            }
        }
    }

    /// One app: download and verify (if MacReplica can), install or hand over to the user, then check the result.
    public func install(_ item: RestoreItem, offer: DownloadOffer?, interaction: GuidedInstallInteraction,
                        isInstalled: @escaping @Sendable (RestoreItem) -> String??) async -> ItemResult {
        if let version = isInstalled(item) { return finish(item, ItemResult(itemID: item.id, outcome: .alreadyPresent, installedVersion: version)) }
        guard let offer else {
            return await waitForUser(item, step: .installYourself, interaction: interaction, isInstalled: isInstalled)
        }
        switch offer.kind {
        case .appStore:
            if let url = URL(string: offer.url) { await interaction.open(url) }
            let step: GuidedStep = offer.appStoreSearchTerm.map { .searchAppStore($0) } ?? .installFromAppStore
            return await waitForUser(item, step: step, interaction: interaction, isInstalled: isInstalled)
        case .vendorWebsite:
            if let url = URL(string: offer.url) { await interaction.open(url) }
            return await waitForUser(item, step: .installFromWebsite, interaction: interaction, isInstalled: isInstalled)
        case .vendorFeed, .homebrewCask:
            guard offer.isDownloadable else {
                return await waitForUser(item, step: .installFromWebsite, interaction: interaction, isInstalled: isInstalled)
            }
        case .ownInstaller:
            return await installOwn(item, offer: offer, interaction: interaction, isInstalled: isInstalled)
        }

        set(item.id, .downloading)
        if await queue.state(item.id) == nil { await queue.enqueue(offer) }
        let file: URL
        switch await waitForDownload(item.id) {
        case .finished(let url): file = url
        case .cancelled: return finish(item, ItemResult(itemID: item.id, outcome: .skipped(.cancelledByUser)))
        case .paused: return finish(item, ItemResult(itemID: item.id, outcome: .skipped(.postponedByUser)))
        case .failed(let error): return failed(item, error)
        default: return failed(item, .network("download did not finish"))
        }

        set(item.id, .verifying)
        let staging = installer.downloadsFolder.appendingPathComponent("staging-" + Hashing.sha256Hex(of: Data(item.id.utf8)).prefix(16))
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            try installer.verifyFile(file, offer: offer)
            log?.info("\(item.id): download verified (\(offer.trust.rawValue))", component: .downloads)
            switch try await installer.prepare(file, offer: offer, staging: staging) {
            case .application(let bundle, let mountPoint):
                set(item.id, .installing)
                do {
                    _ = try installer.installApplication(bundle, source: offer.url)
                } catch DownloadError.applicationsFolderNotWritable {
                    // The user drags the app out of the open image, so it stays mounted for them.
                    await interaction.openInFinder(bundle)
                    return await waitForUser(item, step: .installFromDiskImage, interaction: interaction, isInstalled: isInstalled)
                } catch {
                    if let mountPoint { await installer.detach(mountPoint) }
                    throw error
                }
                if let mountPoint { await installer.detach(mountPoint) }
                guard let version = isInstalled(item) else { return failed(item, .noApplicationFound) }
                log?.info("\(item.id): installed \(version ?? "")", component: .downloads)
                return finish(item, ItemResult(itemID: item.id, outcome: .succeeded, installedVersion: version ?? nil))
            case .suite(let folder, _, let mountPoint):
                set(item.id, .installing)
                let installed = Result { try installer.installSuite(folder, named: offer.suiteFolderName, source: offer.url) }
                if let mountPoint { await installer.detach(mountPoint) }
                _ = try installed.get()
                guard let version = isInstalled(item) else { return failed(item, .noApplicationFound) }
                return finish(item, ItemResult(itemID: item.id, outcome: .succeeded, installedVersion: version ?? nil))
            case .package(let package, _):
                await interaction.openPackage(package)
                return await waitForUser(item, step: .finishInstaller, interaction: interaction, isInstalled: isInstalled)
            case .openInFinder(let url, _):
                await interaction.openInFinder(url)
                return await waitForUser(item, step: .installFromDiskImage, interaction: interaction, isInstalled: isInstalled)
            }
        } catch let error as DownloadError {
            // A file that failed verification is removed and never opened.
            try? FileManager.default.removeItem(at: file)
            return failed(item, error)
        } catch {
            try? FileManager.default.removeItem(at: file)
            return failed(item, .extractionFailed(String(describing: error)))
        }
    }

    /// The user's own installer: copied out of the backup or from its drive, checked against the checksum and
    /// developer recorded on the old Mac, then installed like a verified download. Further packages (e.g. an
    /// activation package) follow in Installer; their effect (a licence) cannot be checked by MacReplica.
    private func installOwn(_ item: RestoreItem, offer: DownloadOffer, interaction: GuidedInstallInteraction,
                            isInstalled: @escaping @Sendable (RestoreItem) -> String??) async -> ItemResult {
        guard let path = offer.localPath, FileManager.default.fileExists(atPath: path) else { return failed(item, .noApplicationFound) }
        set(item.id, .verifying)
        let staging = installer.downloadsFolder.appendingPathComponent("own-" + Hashing.sha256Hex(of: Data(item.id.utf8)).prefix(16))
        defer { try? FileManager.default.removeItem(at: staging) }
        var result: ItemResult
        do {
            let copy = try Self.copyIntoStaging(URL(fileURLWithPath: path), staging: staging)
            try installer.verifyFile(copy, offer: offer)
            log?.info("\(item.id): own installer verified (checksum)", component: .downloads)
            switch try await installer.prepare(copy, offer: offer, staging: staging) {
            case .application(let bundle, let mountPoint):
                set(item.id, .installing)
                let installed = Result { try installer.installApplication(bundle, source: "file://" + path) }
                if let mountPoint { await installer.detach(mountPoint) }
                _ = try installed.get()
                // Verified by what is on disk afterwards, not by the copy having worked.
                guard let version = isInstalled(item) else { return failed(item, .noApplicationFound) }
                result = finish(item, ItemResult(itemID: item.id, outcome: .succeeded, installedVersion: version ?? nil))
            case .suite(let folder, _, let mountPoint):
                set(item.id, .installing)
                let installed = Result { try installer.installSuite(folder, named: offer.suiteFolderName, source: "file://" + path) }
                if let mountPoint { await installer.detach(mountPoint) }
                _ = try installed.get()
                guard let version = isInstalled(item) else { return failed(item, .noApplicationFound) }
                result = finish(item, ItemResult(itemID: item.id, outcome: .succeeded, installedVersion: version ?? nil))
            case .package(let package, _):
                await interaction.openPackage(package)
                result = await waitForUser(item, step: .finishInstaller, interaction: interaction, isInstalled: isInstalled)
            case .openInFinder(let url, _):
                await interaction.openInFinder(url)
                result = await waitForUser(item, step: .installFromDiskImage, interaction: interaction, isInstalled: isInstalled)
            }
        } catch let error as DownloadError {
            return failed(item, error)
        } catch {
            return failed(item, .extractionFailed(String(describing: error)))
        }
        guard result.outcome == .succeeded || result.outcome == .alreadyPresent else { return result }
        var notes = result.notes
        // An app whose developer macOS cannot verify is blocked on its first start until the user allows it.
        if offer.developerUnverified == true, result.outcome == .succeeded { notes.append(.approveInPrivacyAndSecurity(app: item.title)) }
        for package in offer.followUps ?? [] {
            do {
                let copy = try Self.copyIntoStaging(URL(fileURLWithPath: package.path), staging: staging.appendingPathComponent("followup"))
                guard (try? Hashing.sha256Hex(ofFile: copy)) == package.sha256 else { throw DownloadError.checksumMismatch }
                var check = offer
                check.expectedTeamIdentifier = package.teamIdentifier
                check.developerUnverified = package.developerUnverified
                switch try await installer.prepare(copy, offer: check, staging: staging.appendingPathComponent("followup")) {
                case .package(let opened, _): await interaction.openPackage(opened)
                // An unsigned package the user confirmed: shown in Finder, where macOS asks them to approve it.
                case .openInFinder(let shown, _) where package.developerUnverified == true: await interaction.openInFinder(shown)
                default: throw DownloadError.untrustedPackage("not a package")
                }
                switch await interaction.waitForUser(itemID: item.id, step: .finishAdditionalPackage(package.name)) {
                case .checkAgain: notes.append(.additionalPackageOpened(name: package.name))
                default: notes.append(.additionalPackageNotInstalled(name: package.name))
                }
            } catch {
                log?.warning("\(item.id): further package not opened (\(error))", component: .downloads)
                notes.append(.additionalPackageNotInstalled(name: package.name))
            }
        }
        result.notes = notes
        return finish(item, result)
    }

    static func copyIntoStaging(_ file: URL, staging: URL) throws -> URL {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let copy = staging.appendingPathComponent(file.lastPathComponent)
        if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
        try FileManager.default.copyItem(at: file, to: copy)
        return copy
    }

    private func waitForDownload(_ id: String) async -> DownloadState? {
        while true {
            let state = await queue.state(id)
            switch state {
            case .queued?, .downloading?: try? await Task.sleep(nanoseconds: 50_000_000)
            default: return state
            }
            if Task.isCancelled {
                await queue.pause(id)
                return .paused
            }
        }
    }

    private func waitForUser(_ item: RestoreItem, step: GuidedStep, interaction: GuidedInstallInteraction,
                             isInstalled: @escaping @Sendable (RestoreItem) -> String??) async -> ItemResult {
        var notFound = false
        while true {
            set(item.id, .waitingForUser(step))
            let decision = await interaction.waitForUser(itemID: item.id, step: step, notFound: notFound)
            switch decision {
            case .checkAgain:
                if let version = isInstalled(item) {
                    return finish(item, ItemResult(itemID: item.id, outcome: .succeeded, installedVersion: version))
                }
                // Until 1.1.13 the same question came back without a word (tester, 2026-11-03).
                notFound = true
                log?.info("\(item.id): Done, but the app was not found", component: .downloads)
            case .chosen(let app, let confirmed, let copiedFrom, let moved):
                guard confirmed || Self.matches(item, app: app) else { notFound = true; continue }
                let version = ApplicationLocator.version(of: app)
                log?.info("\(item.id): the user chose \(app.lastPathComponent)\(confirmed ? " (confirmed although it differs)" : "")"
                          + (copiedFrom.map { " – \(moved ? "moved" : "copied") from \($0.deletingLastPathComponent().path) to \(app.deletingLastPathComponent().path)" } ?? ""),
                          component: .downloads)
                var notes: [ResultNote] = [.chosenByUser(app: app.lastPathComponent, confirmed: confirmed)]
                if copiedFrom != nil {
                    // The folder as Finder shows it ("Programme" on a German Mac).
                    let folder = FileManager.default.displayName(atPath: app.deletingLastPathComponent().path)
                    notes.append(moved ? .chosenAndMoved(app: app.lastPathComponent, folder: folder)
                                       : .chosenAndCopied(app: app.lastPathComponent, folder: folder))
                }
                return finish(item, ItemResult(itemID: item.id, outcome: .succeeded, installedVersion: version, notes: notes))
            case .skip: return finish(item, ItemResult(itemID: item.id, outcome: .skipped(.userSkipped)))
            case .later: return finish(item, ItemResult(itemID: item.id, outcome: .skipped(.postponedByUser)))
            case .cancel:
                await queue.cancel(item.id)
                return finish(item, ItemResult(itemID: item.id, outcome: .skipped(.cancelledByUser)))
            }
        }
    }

    /// The app the user chose, in an Applications folder: as it is when it already is in one of `folders` (also in a
    /// suite folder there), otherwise copied into the first of them – an app still in the opened installer disk image
    /// or in Downloads is not installed (tester, 2026-11-04: it was counted as installed and never copied).
    /// An app on the same disk in a folder the user can change (Downloads) is moved, like installing it in Finder; one on
    /// a disk image or another drive is copied. Returns the app's place, where it came from (nil when it was already in
    /// place) and whether it was moved.
    public static func placeChosenApp(_ app: URL, in folders: [URL], fileManager: FileManager = .default) throws -> (app: URL, copiedFrom: URL?, moved: Bool) {
        let path = app.standardizedFileURL.resolvingSymlinksInPath().path
        for folder in folders {
            let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
            if path.hasPrefix(base + "/") { return (app, nil, false) }
        }
        guard let destination = folders.first else { throw CocoaError(.fileNoSuchFile) }
        let target = destination.appendingPathComponent(app.lastPathComponent)
        guard !fileManager.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
        if sameVolume(app, destination), fileManager.isWritableFile(atPath: app.deletingLastPathComponent().path) {
            try fileManager.moveItem(at: app, to: target)
            return (target, app, true)
        }
        try fileManager.copyItem(at: app, to: target)
        return (target, app, false)
    }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let first = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let second = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard let first, let second else { return false }
        return first.isEqual(second)
    }

    /// True if the app the user chose is the one in the backup: the same bundle identifier, or – when the backup has
    /// none – the same bundle name.
    public static func matches(_ item: RestoreItem, app: URL) -> Bool {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        if let expected = item.bundleIdentifier?.lowercased() {
            return (info?["CFBundleIdentifier"] as? String)?.lowercased() == expected
        }
        return info != nil && item.appBundleNames.contains(app.lastPathComponent)
    }

    private func failed(_ item: RestoreItem, _ error: DownloadError) -> ItemResult {
        let category: FailureCategory
        switch error {
        case .network, .httpStatus, .tooLarge: category = .network
        case .incompatibleArchitecture, .requiresNewerMacOS: category = .incompatible
        case .alreadyInstalled: category = .appAlreadyExists
        default: category = .downloadNotTrusted
        }
        log?.warning("\(item.id): \(error)", component: .downloads)
        return finish(item, ItemResult(itemID: item.id, outcome: .failed(RestoreFailure(category: category, technicalDetail: String(describing: error)))))
    }

    private func finish(_ item: RestoreItem, _ result: ItemResult) -> ItemResult {
        set(item.id, .finished(result.outcome))
        log?.info("\(item.id): \(result.decisionCode)", component: .downloads)
        return result
    }
}
