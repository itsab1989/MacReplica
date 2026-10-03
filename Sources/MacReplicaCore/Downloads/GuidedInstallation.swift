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
}

/// The step the user is asked to complete.
public enum GuidedStep: Equatable, Sendable {
    case finishInstaller
    case installFromDiskImage
    case installFromWebsite
    case installFromAppStore
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
            return await waitForUser(item, step: .installFromAppStore, interaction: interaction, isInstalled: isInstalled)
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
        for package in offer.followUps ?? [] {
            do {
                let copy = try Self.copyIntoStaging(URL(fileURLWithPath: package.path), staging: staging.appendingPathComponent("followup"))
                guard (try? Hashing.sha256Hex(ofFile: copy)) == package.sha256 else { throw DownloadError.checksumMismatch }
                var check = offer
                check.expectedTeamIdentifier = package.teamIdentifier
                guard case .package(let opened, _) = try await installer.prepare(copy, offer: check, staging: staging.appendingPathComponent("followup")) else {
                    throw DownloadError.untrustedPackage("not a package")
                }
                await interaction.openPackage(opened)
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
        while true {
            set(item.id, .waitingForUser(step))
            let decision = await interaction.waitForUser(itemID: item.id, step: step)
            switch decision {
            case .checkAgain:
                if let version = isInstalled(item) {
                    return finish(item, ItemResult(itemID: item.id, outcome: .succeeded, installedVersion: version))
                }
            case .skip: return finish(item, ItemResult(itemID: item.id, outcome: .skipped(.userSkipped)))
            case .later: return finish(item, ItemResult(itemID: item.id, outcome: .skipped(.postponedByUser)))
            case .cancel:
                await queue.cancel(item.id)
                return finish(item, ItemResult(itemID: item.id, outcome: .skipped(.cancelledByUser)))
            }
        }
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
