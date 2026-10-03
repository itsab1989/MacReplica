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
    let placed = try store.applyAndReloadDock(layout)
    try await Task.sleep(nanoseconds: 10_000_000_000)
    let after = try store.read(macOSVersion: SystemInfo.macOSVersion, work: work)
    try encoder.encode(after).write(to: file.deletingPathExtension().appendingPathExtension("after.json"))
    let installed = Set(after.pages.flatMap { $0 }.flatMap { entry -> [String] in
        if case .folder(_, let pages) = entry { return pages.flatMap { $0 } }
        if case .app(let id) = entry { return [id] }
        return []
    })
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
