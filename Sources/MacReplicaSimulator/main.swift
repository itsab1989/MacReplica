// MacReplicaSimulator — development tool, not shipped with the app.
//
// Creates sandboxed simulation roots with synthetic data and toggles simulated
// failures, so the real MacReplica.app can be validated on screen without
// changing anything on the Mac:
//
//   MacReplicaSimulator create <folder> source|fresh|developer
//   MacReplicaSimulator install-app <folder> <sample app name>   (simulates the user installing an app)
//   MacReplicaSimulator reinstall <folder>                        (simulates erasing macOS on the same Mac)
//   MacReplicaSimulator displays <folder> same-mac|other-mac|external-unplugged
//   MacReplicaSimulator creative <folder>                         (adds Photoshop release/beta and DaVinci Resolve data)
//   MacReplicaSimulator workflow <folder>                         (adds Krita, GIMP, Office, Mail, Cryptomator … data)
//   MacReplicaSimulator launchpad <folder>                        (adds a Launchpad with the sample apps)
//   MacReplicaSimulator install-resolve <folder> <version>        (simulates installing DaVinci Resolve)
//   MacReplicaSimulator launch-photoshop <folder> <folder name>   (simulates opening e.g. "Adobe Photoshop 2026" once)
//   MacReplicaSimulator set <folder> offline|signed-out|brew-broken on|off
//   MacReplicaSimulator set <folder> delay <seconds>
//   MacReplicaSimulator fail-once <folder> <package> <message>
//   MacReplicaSimulator remove <folder>
//
// Launch the app against a root with:
//   MacReplica.app/Contents/MacOS/MacReplica --simulation-root <folder>

import Foundation
import MacReplicaCore
import MacReplicaTestSupport

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: MacReplicaSimulator create <folder> source|fresh|developer
           MacReplicaSimulator install-app <folder> <sample app name>
           MacReplicaSimulator reinstall <folder>
           MacReplicaSimulator displays <folder> same-mac|other-mac|external-unplugged
           MacReplicaSimulator creative <folder>
           MacReplicaSimulator workflow <folder>
           MacReplicaSimulator beta-feedback <folder>
           MacReplicaSimulator launchpad <folder>
           MacReplicaSimulator install-resolve <folder> <version>
           MacReplicaSimulator launch-photoshop <folder> <folder name>
           MacReplicaSimulator set <folder> offline|signed-out|brew-broken on|off
           MacReplicaSimulator set <folder> delay <seconds>
           MacReplicaSimulator fail-once <folder> <package> <message>
           MacReplicaSimulator remove <folder>

    """.utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
// Read-only check of provider detection on this Mac. Prints provider, category and counts
// only — no paths, file names or contents — and changes nothing.
if arguments.first == "detect-live" {
    let layout = SystemLayout.live()
    for detected in AppDataProviders.detect(layout: layout) {
        var shipped: Set<String> = []
        if let package = detected.shippedByPackage {
            shipped = await InventoryService.shippedFiles(package: package, below: detected.folder, layout: layout, runner: ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables), baseEnvironment: [:]))
        }
        let scan = try? AppDataScanner(layout: layout).scan(detected.folder, profile: detected.profile, onlyFiles: detected.files,
                                                            excluding: detected.excluding, scope: detected.scope, shipped: shipped,
                                                            rewritesHomeFolder: detected.rewritesHomeFolder, allowProviderExceptions: true)
        print("appdata \(detected.profile.provider)/\(detected.profile.appVersion ?? "-")/\(detected.profile.category) files=\(scan?.files.count ?? -1)"
              + (scan?.folder.shippedFilesLeftOut.map { " shipped-left-out=\($0)" } ?? ""))
    }
    for provider in CredentialProviders.all { print("credential \(provider.id) detected=\(!provider.detect(layout: layout).isEmpty)") }
    exit(0)
}
// Real-app validation: the real inventory, backup writer and restore of application data on this Mac, limited
// to the given providers. The backup contains only their data; the restore keeps existing files unless
// `replace` is given (then they are moved to "Replaced Files" as in the app).
//   MacReplicaSimulator inspect-installer <file> [file …]
// Runs MacReplica's own installer inspection (the one behind "Use my installer …") on real files and prints one line
// per file: kept or rejected, why, and what was checked. Used for the real-package matrix on every supported macOS.
if arguments.first == "inspect-installer", arguments.count >= 2 {
    let layout = SystemLayout.live()
    let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables),
                                      baseEnvironment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil))
    let inspector = InstallerArchiveInspector(layout: layout, runner: runner)
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("MacReplica-inspect-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: work) }
    let english = Localizer(language: .english)
    for path in arguments.dropFirst() {
        let file = URL(fileURLWithPath: path)
        let started = Date()
        let selection = await inspector.select(file, workFolder: work.appendingPathComponent("w"), bundleStore: work.appendingPathComponent("b"))
        let seconds = String(format: "%.1fs", Date().timeIntervalSince(started))
        switch selection.result {
        case .success(let inspected):
            let a = inspected.archive
            let contents = a.contentsLimit.map { "contents-not-checked:\($0.rawValue)" } ?? (a.hasLicenseAgreement ? "licence-agreement" : "inspected")
            let apps = a.containedApps.map { "\($0.bundleIdentifier ?? "?") \($0.version ?? "?")" }.joined(separator: ", ")
            print("KEPT\t\(file.lastPathComponent)\t\(a.kind.rawValue)\t\(contents)\tapps=[\(apps)]\tpackage=\(a.containsPackage)\t"
                  + "signed=\(a.trustedSignature)\tteam=\(a.teamIdentifier ?? "-")\tarch=\(a.architectures.map(\.rawValue).joined(separator: "+"))\t"
                  + "sha256=\(a.sha256.prefix(16))\t\(seconds)\tnote=\(a.inspectionNote ?? "-")")
        case .failure(let error):
            print("REJECTED\t\(file.lastPathComponent)\t\(error)\t\(seconds)\tnote=\(selection.note ?? "-")\ttext=\(english.installerProblemText(error))")
        }
    }
    exit(0)
}

//   MacReplicaSimulator real-appdata-backup <parent folder> <provider> [provider …]
//   MacReplicaSimulator real-appdata-restore <backup folder> [replace]
if arguments.first == "real-appdata-backup", arguments.count >= 3 {
    let layout = SystemLayout.live()
    let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables),
                                      baseEnvironment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil))
    let providers = Set(arguments.dropFirst(2))
    var inventory = try await InventoryService(layout: layout, runner: runner, catalogProvider: RemoteCatalogProvider(cacheFolder: layout.caches),
                                               macOSVersion: SystemInfo.macOSVersion, architecture: SystemInfo.currentArchitecture).run()
    for folder in inventory.manifest.applicationData where !providers.contains(folder.profile?.provider ?? "") {
        inventory.removeApplicationData(id: folder.id)
    }
    inventory.excludeFiles(Set(inventory.fonts.map { InventoryResult.selectionID($0.record, kind: .font) }
        + inventory.colorProfiles.map { InventoryResult.selectionID($0.record, kind: .colorProfile) }))
    inventory.keepPythonEnvironments([], includeSettings: false)
    inventory.keepToolchains([])
    inventory.manifest.displayProfiles = []
    inventory.manifest.launchpadLayout = nil
    let log = LogStore(fileURL: nil, homeDirectory: layout.homeDirectory)
    let outcome = try BackupWriter(layout: layout, localizer: Localizer(language: .english)).write(inventory, into: URL(fileURLWithPath: arguments[1]), log: log)
    for folder in outcome.manifest.applicationData {
        print("backed up \(folder.profile?.provider ?? "-")/\(folder.profile?.category ?? "-"): \(folder.files.count) files "
              + "[\(folder.profile?.effectiveConfidence.rawValue ?? "-")] \(folder.displayPath)")
    }
    for issue in outcome.manifest.backupIssues { print("issue: \(issue)") }
    print("verified: \(BackupVerifier(layout: layout).verify(backupAt: outcome.url).isIntact)")
    print(outcome.url.path)
    exit(0)
}
// Real Homebrew end to end for a developer's own tap (ChromIQ): the real inventory finds a stand-in ChromIQ bundle and
// assigns the tap; the real restore adds and trusts the tap and installs the cask with the real Homebrew – into a
// scratch folder (HOMEBREW_CASK_OPTS --appdir), so /Applications stays untouched. Removing the cask and tap afterwards is
// left to the caller (with HOMEBREW_NO_AUTOREMOVE=1).
//   MacReplicaSimulator real-tap-e2e <scratch folder>
if arguments.first == "real-tap-e2e", arguments.count == 2 {
    struct AppDirRunner: CommandRunning {
        let base: CommandRunning
        let appdir: String
        func run(_ command: Command, onOutputLine: (@Sendable (String) -> Void)?) async throws -> CommandResult {
            var command = command
            if command.executable.hasSuffix("/brew") { command.environment["HOMEBREW_CASK_OPTS"] = "--appdir=\(appdir)" }
            return try await base.run(command, onOutputLine: onOutputLine)
        }
    }
    let scratch = URL(fileURLWithPath: arguments[1])
    let oldMac = scratch.appendingPathComponent("old-mac/Applications")
    let newMac = scratch.appendingPathComponent("new-mac/Applications")
    let contents = oldMac.appendingPathComponent("ChromIQ.app/Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: newMac, withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.chromiq.app", "CFBundleName": "ChromIQ",
                                                          "CFBundleShortVersionString": "1.0"], format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    var layout = SystemLayout.live()
    layout.applicationFolders = [oldMac]
    let base = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables),
                                    baseEnvironment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil))
    let inventory = try await InventoryService(layout: layout, runner: base, catalogProvider: RemoteCatalogProvider(cacheFolder: layout.caches),
                                               macOSVersion: SystemInfo.macOSVersion, architecture: SystemInfo.currentArchitecture).run()
    guard let app = inventory.manifest.applications.first(where: { $0.bundleIdentifier == "com.chromiq.app" }) else { print("FAIL: ChromIQ not found"); exit(1) }
    print("inventory: \(app.name) → \(app.restoreMethod)")
    var manifest = inventory.manifest
    manifest.applications = [app]
    manifest.brewFormulae = []
    manifest.brewCasks = []
    manifest.brewTaps = manifest.brewTaps.filter { $0.suggestedFor?.contains(app.name) == true }
    print("taps: \(manifest.brewTaps.map { "\($0.name) (\($0.remote ?? "-"), for \($0.suggestedFor ?? []))" })")
    var restoreLayout = SystemLayout.live()
    restoreLayout.applicationFolders = [newMac]
    let runner = AppDirRunner(base: base, appdir: newMac.path)
    // As the app starts the restore selection: documented developer taps are allowed by default.
    let selection = RestoreSelection(components: [.applications, .brewFormulae, .brewCasks], enabledTaps: VendorTaps.defaultEnabledTaps(manifest))
    print("enabled taps: \(selection.enabledTaps.sorted())")
    let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
    print("plan: \(plan.items.map { "\($0.kind) \($0.identifier)" })")
    let log = LogStore(fileURL: nil, homeDirectory: restoreLayout.homeDirectory)
    var environment = RestoreEnvironment(layout: restoreLayout, runner: runner, privileged: AppleScriptPrivilegedExecutor(runner: runner, osascript: restoreLayout.osascript),
                                         homebrewSource: GitHubHomebrewPackageSource(runner: runner, pkgutil: restoreLayout.pkgutil),
                                         localizer: Localizer(language: .english), log: log)
    environment.isApplicationRunning = { _ in false }
    let executor = RestoreExecutor(environment: environment, backupRoot: scratch, sessionStore: nil)
    let localizer = Localizer(language: .english)
    for entry in await executor.dryRun(plan: plan, selection: selection) {
        print("dry run \(entry.item.title): \(localizer.predictionText(entry.prediction, kind: entry.item.kind))")
    }
    let session = await executor.run(plan: plan, session: RestoreSession(backupPath: scratch.path, selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
    for item in plan.items {
        guard let result = session.results[item.id] else { continue }
        print("restored \(item.title) [\(item.identifier)]: \(localizer.outcomeText(result.outcome)) \(result.notes.map { localizer.noteText($0) })")
    }
    let installed = (try? FileManager.default.contentsOfDirectory(atPath: newMac.path)) ?? []
    print("new Mac Applications: \(installed)")
    for name in installed where name.hasSuffix(".app") {
        let info = NSDictionary(contentsOf: newMac.appendingPathComponent("\(name)/Contents/Info.plist")) as? [String: Any]
        print("  \(name): \(info?["CFBundleIdentifier"] ?? "-") \(info?["CFBundleShortVersionString"] ?? "-")")
    }
    exit(0)
}
if arguments.first == "real-appdata-restore", arguments.count >= 2 {
    let layout = SystemLayout.live()
    let runner = ProcessCommandRunner(policy: CommandPolicy(allowedExecutables: layout.allowedExecutables),
                                      baseEnvironment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil))
    let backup = URL(fileURLWithPath: arguments[1])
    let manifest = try ManifestIO.read(from: backup)
    var selection = RestoreSelection(components: [.applicationData])
    if arguments.dropFirst(2).contains("replace") { selection.conflictResolution = .replace }
    let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
    let log = LogStore(fileURL: nil, homeDirectory: layout.homeDirectory)
    var environment = RestoreEnvironment(layout: layout, runner: runner, privileged: AppleScriptPrivilegedExecutor(runner: runner, osascript: layout.osascript),
                                         homebrewSource: GitHubHomebrewPackageSource(runner: runner, pkgutil: layout.pkgutil),
                                         localizer: Localizer(language: .english), log: log)
    environment.isApplicationRunning = { _ in false }
    let executor = RestoreExecutor(environment: environment, backupRoot: backup, sessionStore: nil)
    let localizer = Localizer(language: .english)
    for entry in await executor.dryRun(plan: plan, selection: selection) {
        print("dry run \(entry.item.title): \(localizer.predictionText(entry.prediction, kind: entry.item.kind))")
    }
    let session = await executor.run(plan: plan, session: RestoreSession(backupPath: backup.path, selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
    for item in plan.items {
        guard let result = session.results[item.id] else { continue }
        print("restored \(item.title) [\(item.identifier)]: \(localizer.outcomeText(result.outcome)) \(result.notes.map { localizer.noteText($0) })")
    }
    exit(0)
}
// Where Launchpad's database is: the user's folder, the file the running Dock has open, and what MacReplica uses.
//   MacReplicaSimulator launchpad-locate
if arguments.first == "launchpad-locate" {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let computed = confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count) > 0 ? String(cString: buffer) + "com.apple.dock.launchpad/db/db" : "-"
    print("computed: \(computed) exists=\(FileManager.default.fileExists(atPath: computed))")
    print("dock has open: \(LaunchpadStore.openDockDatabase()?.path ?? "-")")
    let store = LaunchpadStore.live()
    print("used: \(store?.database.path ?? "-") (\(store?.sourceReport ?? "-"))")
    exit(store.map { FileManager.default.fileExists(atPath: $0.database.path) } == true ? 0 : 1)
}

// Launchpad on macOS 13–15: export the current user's layout, or rebuild a layout, restart the Dock and verify.
//   MacReplicaSimulator launchpad-export <file.json>
//   MacReplicaSimulator launchpad-apply <file.json>     (prints MATCH when the Dock shows the layout afterwards)
if arguments.first == "launchpad-export" || arguments.first == "launchpad-apply", arguments.count == 2 {
    guard let store = LaunchpadStore.live() else { print("no Launchpad database location"); exit(2) }
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("mr-launchpad-\(getpid())")
    let file = URL(fileURLWithPath: arguments[1])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if arguments.first == "launchpad-export" {
        let layout = try store.read(macOSVersion: SystemInfo.macOSVersion, work: work)
        try encoder.encode(layout).write(to: file)
        print("exported \(layout.pages.count) pages, folders: \(layout.folderNames)")
        exit(0)
    }
    let layout = try JSONDecoder().decode(LaunchpadLayout.self, from: Data(contentsOf: file))
    var written: LaunchpadLayout?
    let placed = try store.applyAndReloadDock(layout, signal: { signal in
        if signal == SIGKILL { written = try? store.read(macOSVersion: SystemInfo.macOSVersion, work: work) }
        LaunchpadStore.signalDock(signal)
    })
    if let written {
        try encoder.encode(written).write(to: file.deletingPathExtension().appendingPathExtension("written.json"))
        print("written (before the Dock restart): \(written.pages.count) pages, folders: \(written.folderNames); "
              + (layout.matches(written, installed: written.appEntryCounts) ? "as recorded" : "differs"))
    }
    try await Task.sleep(nanoseconds: 10_000_000_000)
    let after = try store.read(macOSVersion: SystemInfo.macOSVersion, work: work)
    try encoder.encode(after).write(to: file.deletingPathExtension().appendingPathExtension("after.json"))
    let installed = after.appEntryCounts
    print("placed \(placed) apps; after the Dock restart: \(after.pages.count) pages, folders: \(after.folderNames)")
    print(layout.matches(after, installed: installed) ? "MATCH" : "MISMATCH")
    exit(layout.matches(after, installed: installed) ? 0 : 1)
}

// Checks the live ColorSync access without changing anything visible: every connected display that has a
// custom profile gets that same profile assigned again, and the assignment is read back. Prints no names.
if arguments.first == "display-check-live" {
    let manager = LiveDisplayColorManager()
    let displays = manager.displays()
    print("displays=\(displays.count) connected=\(displays.filter(\.isConnected).count) platformIdentifier=\(manager.platformIdentifier() != nil)")
    for (index, display) in displays.enumerated() where display.isConnected {
        guard let profile = display.customProfile else { print("display\(index) builtIn=\(display.isBuiltIn ?? false) customProfile=none"); continue }
        let reassigned = manager.assign(profile, toDisplay: display.uuid)
        let readBack = manager.displays().first { $0.uuid == display.uuid }?.customProfile?.standardizedFileURL == profile.standardizedFileURL
        print("display\(index) builtIn=\(display.isBuiltIn ?? false) customProfile=yes reassignSameProfile=\(reassigned) readBackMatches=\(readBack)")
    }
    exit(0)
}
guard arguments.count >= 2 else { usage() }
let folder = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let root = SimulationRoot(url: folder)

do {
    switch arguments[0] {
    case "create":
        guard arguments.count == 3 else { usage() }
        let scenario: SimulationBuilder.Scenario = ["source": .sourceMac, "developer": .developerMac][arguments[2]] ?? .freshMac
        try SimulationBuilder.create(at: folder, scenario: scenario)
        print("Created \(scenario.rawValue) simulation at \(folder.path)")
    case "reinstall":
        try root.simulateReinstall()
        print("Simulated a macOS reinstall on the same Mac")
    case "displays":
        guard arguments.count == 3 else { usage() }
        let builtIn = SimulationBuilder.builtInDisplay, external = SimulationBuilder.externalDisplay
        switch arguments[2] {
        case "same-mac":
            try root.configureDisplays(platform: "SIMULATED-MAC-A", displays: [(builtIn, "Built-in Display", true, true, nil), (external, "Example Studio Display", false, true, nil)])
        case "other-mac":
            try root.configureDisplays(platform: "SIMULATED-MAC-B", displays: [("00000000-0000-4000-8000-00000000C333", "Built-in Display", true, true, nil),
                                                                                (external, "Example Studio Display", false, true, nil)])
        case "external-unplugged":
            try root.configureDisplays(platform: "SIMULATED-MAC-A", displays: [(builtIn, "Built-in Display", true, true, nil), (external, "Example Studio Display", false, false, nil)])
        default: usage()
        }
        print("Displays: \(arguments[2])")
    case "creative":
        try root.addCreativeAppData()
        print("Added Photoshop and DaVinci Resolve data")
    case "workflow":
        try root.addWorkflowAppData()
        print("Added Krita, GIMP, Inkscape, Scribus, Office, Mail, Cryptomator, DisplayCAL and other app data")
    case "corner-store":
        // Validation only: MacReplica's real corner write path into a test app's own domain (never the global one).
        // corner-store <domain> <points|system|restore:<history text>>
        guard arguments.count > 2, arguments[1].contains("."), arguments[1] != "NSGlobalDomain" else { usage() }
        let tool = WindowCornersTool(store: LiveGlobalPreferenceStore(application: arguments[1]), environment: .current)
        let request = arguments[2]
        if request.hasPrefix("restore:"), let previous = CornerSnapshot(historyText: String(request.dropFirst(8))) {
            let result = try tool.restore(previous)
            print("restored", result.after.historyText.isEmpty ? "(nothing set)" : result.after.historyText, result.outcome.rawValue)
        } else {
            let configuration: CornerConfiguration = request == "system"
                ? CornerConfiguration() : .uniform(Int(request) ?? 0, surfaces: [.windows, .utilityPanels])
            let result = try tool.apply(configuration)
            print("before", result.before.historyText.isEmpty ? "-" : result.before.historyText)
            print("after", result.outcome.rawValue)
        }
    case "beta-feedback":
        try root.addBetaFeedbackApps()
        print("Added Cakebrew (cask removed), the DisplayCAL suite (cask disabled), ChromIQ (vendor tap) and Tap Tool (tapped tap)")
    case "launchpad":
        // A Launchpad with the sample apps on one page and a folder (the simulated Dock is never signalled).
        let apps = ["com.example.nimbusnotes", "com.example.pixelforge", "org.example.orbit", "com.example.terminalplus", "com.example.ledgerlite", "com.example.quillwriter", "com.example.studiomixer"]
        try SyntheticLaunchpad.create(at: root.state.appendingPathComponent("launchpad/db/db"),
                                      apps: Array(apps.suffix(from: min(3, apps.count))) + ["com.apple.Safari"], folder: Array(apps.prefix(3)))
        print("Added a Launchpad with \(apps.count + 1) apps")
    case "install-resolve":
        guard arguments.count == 3 else { usage() }
        try root.installResolve(version: arguments[2])
        print("Installed DaVinci Resolve \(arguments[2])")
    case "launch-photoshop":
        guard arguments.count == 3 else { usage() }
        try root.launchPhotoshop(arguments[2])
        print("Opened \(arguments[2]) once")
    case "install-app":
        guard arguments.count == 3 else { usage() }
        try root.simulateUserInstall(appNamed: arguments[2])
        print("Installed \(arguments[2])")
    case "set":
        guard arguments.count == 4 else { usage() }
        let on = arguments[3] == "on"
        switch arguments[2] {
        case "offline": try root.setOffline(on)
        case "signed-out": try root.setAppStoreSignedOut(on)
        case "brew-broken": try root.setHomebrewBroken(on)
        case "delay": try root.setDelay(Double(arguments[3]) ?? 0)
        default: usage()
        }
    case "fail-once":
        guard arguments.count == 4 else { usage() }
        try root.failOnce(arguments[2], message: arguments[3])
    case "remove":
        try SafeCleaner(homeDirectory: FileManager.default.homeDirectoryForCurrentUser).removeOwnedFolder(folder, kind: .simulation)
        print("Removed \(folder.path)")
    default:
        usage()
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
