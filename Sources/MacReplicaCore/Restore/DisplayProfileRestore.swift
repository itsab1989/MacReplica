import Foundation

/// What a display step finds on this Mac.
enum DisplayProfileState: Equatable {
    case ready(display: DisplayDevice, profile: URL)
    case alreadyAssigned
    /// The profile is restored by an earlier step of this restore.
    case waitingForProfile
    case displayNotConnected
    case displayOfAnotherMac
    case profileNotAvailable
}

extension Inspector {
    var displayManager: DisplayColorManaging { environment.displayColor ?? layout.displayColorManager }

    /// The profile file on this Mac: the backed-up profile (wherever an identical copy is), or the macOS profile.
    func displayProfileURL(_ assignment: DisplayProfileAssignment) -> URL? {
        switch assignment.source {
        case .macOS:
            guard let relative = assignment.macOSProfile, let url = PathSafety.resolve(relative, inside: layout.macOSColorProfiles),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        case .backedUp:
            guard let sha = assignment.profileSHA256 else { return nil }
            let index = fileIndexes.index(.colorProfile, layout: layout)
            return index.entries.first { index.hash(of: $0) == sha }?.url
        }
    }

    func displayProfileState(_ item: RestoreItem) -> DisplayProfileState {
        guard let assignment = item.displayAssignment, let keys = item.hardwareKeys else { return .profileNotAvailable }
        let manager = displayManager
        let display = manager.displays().first { keys.key(for: $0.uuid) == assignment.displayKey }
        guard let display, display.isConnected else {
            // A built-in display only exists on the Mac the backup was made on.
            if assignment.isBuiltIn == true, keys.isSameMac(platformIdentifier: manager.platformIdentifier()) != true { return .displayOfAnotherMac }
            return .displayNotConnected
        }
        guard let profile = displayProfileURL(assignment) else {
            return item.dependsOn.isEmpty ? .profileNotAvailable : .waitingForProfile
        }
        if display.customProfile?.standardizedFileURL.resolvingSymlinksInPath() == profile.standardizedFileURL.resolvingSymlinksInPath() {
            return .alreadyAssigned
        }
        return .ready(display: display, profile: profile)
    }

    func predictDisplayProfile(_ item: RestoreItem) -> Prediction {
        switch displayProfileState(item) {
        case .ready: return .willInstall
        case .alreadyAssigned: return .alreadyPresent(version: nil)
        case .waitingForProfile: return .dependsOnEarlierStep
        case .displayNotConnected: return .manualStep
        case .displayOfAnotherMac: return .willSkip(.displayOfAnotherMac)
        case .profileNotAvailable: return .willSkip(.profileNotAvailable)
        }
    }
}

extension RestoreExecutor {
    /// Assigns the profile to the same display as on the old Mac, in the current user's ColorSync settings,
    /// and confirms it by reading the assignment back. Displays that are not connected wait for the user.
    func restoreDisplayProfile(_ item: RestoreItem, inspector: Inspector, onEvent: @escaping @Sendable (RestoreEvent) -> Void) -> ItemResult {
        let name = item.displayAssignment?.displayName ?? item.title
        switch inspector.displayProfileState(item) {
        case .alreadyAssigned:
            return ItemResult(itemID: item.id, outcome: .alreadyPresent)
        case .displayNotConnected, .waitingForProfile:
            return ItemResult(itemID: item.id, outcome: .skipped(.displayNotConnected(name: name)))
        case .displayOfAnotherMac:
            return ItemResult(itemID: item.id, outcome: .skipped(.displayOfAnotherMac))
        case .profileNotAvailable:
            return ItemResult(itemID: item.id, outcome: .skipped(.profileNotAvailable))
        case .ready(let display, let profile):
            onEvent(.activity(itemID: item.id, .installing))
            let manager = inspector.displayManager
            let reported = manager.assign(profile, toDisplay: display.uuid)
            onEvent(.activity(itemID: item.id, .verifying))
            let assigned = manager.displays().first { $0.uuid == display.uuid }?.customProfile
            guard reported, assigned?.standardizedFileURL.resolvingSymlinksInPath() == profile.standardizedFileURL.resolvingSymlinksInPath() else {
                return failed(item, .verificationFailed, "display profile not assigned")
            }
            log.info("\(item.id): profile assigned to \(name)", component: .restore)
            return ItemResult(itemID: item.id, outcome: .succeeded)
        }
    }
}
