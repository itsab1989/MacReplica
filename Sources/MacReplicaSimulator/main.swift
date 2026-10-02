// MacReplicaSimulator — development tool, not shipped with the app.
//
// Creates sandboxed simulation roots with synthetic data and toggles simulated
// failures, so the real MacReplica.app can be validated on screen without
// changing anything on the Mac:
//
//   MacReplicaSimulator create <folder> source|fresh
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
    usage: MacReplicaSimulator create <folder> source|fresh
           MacReplicaSimulator set <folder> offline|signed-out|brew-broken on|off
           MacReplicaSimulator set <folder> delay <seconds>
           MacReplicaSimulator fail-once <folder> <package> <message>
           MacReplicaSimulator remove <folder>

    """.utf8))
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { usage() }
let folder = URL(fileURLWithPath: arguments[1]).standardizedFileURL
let root = SimulationRoot(url: folder)

do {
    switch arguments[0] {
    case "create":
        guard arguments.count == 3 else { usage() }
        let scenario: SimulationBuilder.Scenario = arguments[2] == "source" ? .sourceMac : .freshMac
        try SimulationBuilder.create(at: folder, scenario: scenario)
        print("Created \(scenario.rawValue) simulation at \(folder.path)")
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
