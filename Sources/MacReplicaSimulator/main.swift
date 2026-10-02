// MacReplicaSimulator — development tool, not shipped with the app.
//
// Creates sandboxed simulation roots with synthetic data and toggles simulated
// failures, so the real MacReplica.app can be validated on screen without
// changing anything on the Mac:
//
//   MacReplicaSimulator create <folder> source|fresh|developer
//   MacReplicaSimulator install-app <folder> <sample app name>   (simulates the user installing an app)
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
        let count = (try? AppDataScanner(layout: layout).scan(detected.folder, profile: detected.profile, onlyFiles: detected.files,
                                                              excluding: detected.excluding).files.count) ?? -1
        print("appdata \(detected.profile.provider)/\(detected.profile.category) files=\(count)")
    }
    for provider in CredentialProviders.all { print("credential \(provider.id) detected=\(!provider.detect(layout: layout).isEmpty)") }
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
