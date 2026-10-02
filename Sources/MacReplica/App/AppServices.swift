import Foundation
import MacReplicaCore

/// The concrete implementations the app works with: the real system, or a
/// sandboxed simulation when launched with `--simulation-root <folder>`.
struct AppServices: Sendable {
    let layout: SystemLayout
    let runner: CommandRunning
    let catalogProvider: CatalogProviding
    let privileged: PrivilegedExecuting
    let homebrewSource: HomebrewPackageSource
    let macOSVersion: String
    let architecture: CPUArchitecture
    let askpassPath: String?
    let defaultsSuite: String?
    let simulationRoot: URL?
    let releaseFetcher: ReleaseFetching

    static func make(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppServices {
        if let simulation = SimulationEnvironment.fromLaunchArguments(arguments) {
            return AppServices(
                layout: simulation.layout,
                runner: simulation.makeRunner(),
                catalogProvider: simulation.makeCatalogProvider(),
                privileged: simulation.makePrivilegedExecutor(),
                homebrewSource: simulation.makeHomebrewSource(),
                macOSVersion: simulation.config.macosVersion,
                architecture: simulation.config.architecture,
                askpassPath: nil,
                // Simulation runs keep their own preferences so they never touch the real ones.
                defaultsSuite: "io.github.itsab1989.MacReplica.simulation",
                simulationRoot: simulation.root,
                // Update checks in the simulation read controlled release data, never GitHub.
                releaseFetcher: LocalReleaseFetcher(file: simulation.root.appendingPathComponent("releases/releases.json")))
        }
        let layout = SystemLayout.live()
        let runner = ProcessCommandRunner(
            policy: CommandPolicy(allowedExecutables: layout.allowedExecutables),
            baseEnvironment: layout.processEnvironment(homebrewPrefix: nil, askpass: nil))
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MacReplicaAskpass").path
        return AppServices(
            layout: layout,
            runner: runner,
            catalogProvider: RemoteCatalogProvider(cacheFolder: layout.caches),
            privileged: AppleScriptPrivilegedExecutor(runner: runner, osascript: layout.osascript),
            homebrewSource: GitHubHomebrewPackageSource(runner: runner, pkgutil: layout.pkgutil),
            macOSVersion: SystemInfo.macOSVersion,
            architecture: SystemInfo.currentArchitecture,
            askpassPath: FileManager.default.isExecutableFile(atPath: helper) ? helper : nil,
            defaultsSuite: nil,
            simulationRoot: nil,
            releaseFetcher: GitHubReleaseFetcher())
    }

    var defaults: UserDefaults {
        defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    var sessionStore: SessionStore {
        SessionStore(folder: layout.applicationSupport.appendingPathComponent("Sessions"), homeDirectory: layout.homeDirectory)
    }
}
