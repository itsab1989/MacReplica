import Foundation

public struct RestorePlan: Equatable, Sendable {
    /// Steps in execution order. Prerequisites come first.
    public var items: [RestoreItem]
    /// Apps that MacReplica cannot install automatically; shown with links and hints.
    public var manualApps: [AppRecord]

    public func item(id: String) -> RestoreItem? { items.first { $0.id == id } }
}

/// Turns a manifest and the user's selection into an ordered restore plan.
public struct RestorePlanner: Sendable {
    public init() {}

    /// All items the backup could restore, before the user's individual exclusions.
    /// The restore screen uses this list for the individual program selection.
    public func candidateItems(manifest: Manifest, selection: RestoreSelection) -> [RestoreItem] {
        // Everything the backup could restore, independent of what is switched on right now,
        // so that components that are off by default (credentials) can still be offered.
        var unrestricted = selection
        unrestricted.excludedItemIDs = []
        unrestricted.components = Set(RestoreComponent.allCases)
        return plan(manifest: manifest, selection: unrestricted).items.filter { $0.component != nil }
    }

    /// Continues an interrupted restore with a changed selection. Steps that already finished stay in
    /// the session with their results (they are not run again and cannot be deselected); the remaining
    /// steps follow the new selection. Order and dependencies come from the full plan.
    public func continuation(of session: RestoreSession, manifest: Manifest, selection: RestoreSelection) -> (RestorePlan, RestoreSession) {
        let chosen = plan(manifest: manifest, selection: selection)
        var everything = selection
        everything.components = Set(RestoreComponent.allCases)
        everything.excludedItemIDs = []
        let full = plan(manifest: manifest, selection: everything)
        let wanted = Set(chosen.items.map(\.id)).union(session.results.keys)
        let merged = RestorePlan(items: full.items.filter { wanted.contains($0.id) }, manualApps: chosen.manualApps)
        var continued = session
        continued.selection = selection
        continued.itemIDs = merged.items.map(\.id)
        return (merged, continued)
    }

    public func plan(manifest: Manifest, selection: RestoreSelection) -> RestorePlan {
        var taps: [String: RestoreItem] = [:]
        var formulae: [RestoreItem] = []
        var casks: [RestoreItem] = []
        var appStore: [RestoreItem] = []
        var files: [RestoreItem] = []
        var manual: [AppRecord] = []
        var manualItems: [RestoreItem] = []
        var caskTokens = Set<String>()
        let components = selection.components

        func tapDependency(for tap: String?) -> [String] {
            guard let tap, !tap.isEmpty else { return [] }
            let record = manifest.brewTaps.first { $0.name.lowercased() == tap.lowercased() } ?? BrewTapRecord(name: tap)
            guard !record.isBuiltIn else { return [] }
            let id = "tap:\(record.name.lowercased())"
            if taps[id] == nil {
                taps[id] = RestoreItem(id: id, kind: .tap, title: record.name, identifier: record.name,
                                       tapRemote: record.remote, dependsOn: [RestoreItem.homebrewID])
            }
            return [id]
        }

        // Applications the backup knows about, keyed by cask token for verification details.
        var appsByToken: [String: AppRecord] = [:]
        for app in manifest.applications {
            if case .homebrewCask(let token) = app.restoreMethod { appsByToken[token] = app }
        }

        if components.contains(.brewCasks) {
            for cask in manifest.brewCasks {
                let app = appsByToken[cask.token]
                let names = cask.appArtifacts.isEmpty ? (app.map { [$0.bundleFileName] } ?? []) : cask.appArtifacts
                casks.append(RestoreItem(
                    id: "cask:\(cask.token)", kind: .cask, title: app?.name ?? cask.token, identifier: cask.token,
                    originalVersion: cask.version, bundleIdentifier: app?.bundleIdentifier, appBundleNames: names,
                    architectures: app?.architectures ?? [],
                    dependsOn: [RestoreItem.homebrewID] + tapDependency(for: cask.tap), component: .brewCasks))
                caskTokens.insert(cask.token)
            }
        }

        if components.contains(.applications) {
            for app in manifest.applications {
                if case .homebrewCask = app.source { continue }
                if app.source == .appStore || app.restoreMethod.category == .appStore { continue }
                var method = app.restoreMethod
                if let decision = selection.matchDecisions[app.path] {
                    if decision.isEmpty {
                        method = app.homepage.map { .officialDownload(url: $0) } ?? .manual
                    } else if let candidate = app.candidates.first(where: { $0.token == decision }) {
                        method = candidate.restoreMethod
                    }
                }
                switch method {
                case .homebrewCask(let token):
                    guard !caskTokens.contains(token) else { continue }
                    casks.append(RestoreItem(
                        id: "cask:\(token)", kind: .cask, title: app.name, identifier: token,
                        originalVersion: app.version, bundleIdentifier: app.bundleIdentifier,
                        appBundleNames: [app.bundleFileName], architectures: app.architectures,
                        dependsOn: [RestoreItem.homebrewID], component: .applications))
                    caskTokens.insert(token)
                case .homebrewFormula(let name):
                    formulae.append(RestoreItem(
                        id: "formula:\(name)", kind: .formula, title: app.name, identifier: name,
                        originalVersion: app.version, bundleIdentifier: app.bundleIdentifier,
                        dependsOn: [RestoreItem.homebrewID], component: .applications))
                case .officialDownload, .manual, .appStore:
                    if !selection.excludedItemIDs.contains("manual:\(app.path)") { manual.append(app) }
                    var item = RestoreItem(
                        id: "manual:\(app.path)", kind: .manualApp, title: app.name, identifier: app.path,
                        originalVersion: app.version, bundleIdentifier: app.bundleIdentifier,
                        appBundleNames: [app.bundleFileName], architectures: app.architectures, component: .applications)
                    item.app = app
                    manualItems.append(item)
                }
            }
        }

        if components.contains(.brewFormulae) {
            for formula in manifest.brewFormulae where formula.installedOnRequest {
                let id = "formula:\(formula.name)"
                guard !formulae.contains(where: { $0.id == id }) else { continue }
                formulae.append(RestoreItem(
                    id: id, kind: .formula, title: formula.name, identifier: formula.name, originalVersion: formula.version,
                    dependsOn: [RestoreItem.homebrewID] + tapDependency(for: formula.tap), component: .brewFormulae))
            }
        }

        if components.contains(.appStore) {
            var seen = Set<Int>()
            var entries = manifest.masApps
            for app in manifest.applications {
                if case .appStore(let id) = app.restoreMethod, !entries.contains(where: { $0.appStoreID == id }) {
                    entries.append(MASAppRecord(appStoreID: id, name: app.name, version: app.version, bundleIdentifier: app.bundleIdentifier))
                }
            }
            for entry in entries where seen.insert(entry.appStoreID).inserted {
                let app = manifest.applications.first {
                    if case .appStore(let id) = $0.restoreMethod { return id == entry.appStoreID }
                    return entry.bundleIdentifier != nil && $0.bundleIdentifier == entry.bundleIdentifier
                }
                appStore.append(RestoreItem(
                    id: "mas:\(entry.appStoreID)", kind: .appStoreApp, title: entry.name, identifier: String(entry.appStoreID),
                    originalVersion: entry.version, bundleIdentifier: entry.bundleIdentifier ?? app?.bundleIdentifier,
                    appBundleNames: app.map { [$0.bundleFileName] } ?? [], architectures: app?.architectures ?? [],
                    component: .appStore))
            }
        }

        // Version managers, runtimes and global tools.
        var toolchainItems: [RestoreItem] = []
        func homebrewItem(_ package: HomebrewPackageReference, title: String, component: RestoreComponent) -> String {
            let id = package.itemID
            switch package.kind {
            case .formula where !formulae.contains(where: { $0.id == id }):
                formulae.append(RestoreItem(id: id, kind: .formula, title: title, identifier: package.name,
                                            dependsOn: [RestoreItem.homebrewID], component: component))
            case .cask where !casks.contains(where: { $0.id == id }):
                casks.append(RestoreItem(id: id, kind: .cask, title: title, identifier: package.name,
                                         dependsOn: [RestoreItem.homebrewID], component: component))
                caskTokens.insert(package.name)
            default: break
            }
            return id
        }
        for record in manifest.toolchains {
            let component: RestoreComponent = record.ecosystem == .packageManagers ? .packageManagers : .developerTools
            guard components.contains(component) else { continue }
            let provider = ToolchainCatalog.provider(record.provider)
            let name = provider.descriptor.name
            for runtime in record.runtimes {
                if let package = provider.homebrewPackage(for: runtime) {
                    _ = homebrewItem(package, title: [runtime.vendor, "\(name) \(runtime.version)"].compactMap { $0 }.joined(separator: " · "),
                                     component: component)
                }
            }
            let actions = provider.restoreActions(for: record)
            guard !actions.isEmpty else { continue }
            var managerID: String?
            if let package = provider.managerPackage(for: record), actions.contains(where: { $0.kind != .manager }) {
                managerID = homebrewItem(package, title: name, component: component)
            } else if let manager = actions.first(where: { $0.kind == .manager }) {
                managerID = manager.itemID
            }
            for action in actions {
                var dependsOn: [String] = []
                if action.kind != .manager, let managerID { dependsOn.append(managerID) }
                if let runtime = action.package?.runtime {
                    switch runtime.source {
                    case .manager:
                        if let owner = runtime.provider {
                            dependsOn.append(ToolchainAction(provider: owner, kind: .runtime, runtime: ToolchainRuntime(version: runtime.version)).itemID)
                        }
                    case .homebrew:
                        dependsOn.append(homebrewItem(.formula(runtime.version), title: runtime.version, component: component))
                    case .other:
                        break
                    }
                }
                // Programs installed with Cargo need rustup's default toolchain.
                if action.provider == .cargo, let rustup = manifest.toolchains.first(where: { $0.provider == .rustup }),
                   let toolchain = rustup.runtimes.first(where: \.isDefault) ?? rustup.runtimes.first {
                    dependsOn.append(ToolchainAction(provider: .rustup, kind: .runtime, runtime: toolchain).itemID)
                }
                var item = RestoreItem(id: action.itemID, kind: .toolchainStep, title: action.title, identifier: record.provider.rawValue,
                                       originalVersion: action.runtime?.version ?? action.package?.version,
                                       dependsOn: dependsOn, component: component)
                item.toolchain = action
                toolchainItems.append(item)
            }
        }
        // Managers first, then runtimes, environments and packages, so that dependencies come before what needs them.
        let actionOrder: [ToolchainAction.Kind: Int] = [.manager: 0, .runtime: 1, .environment: 2, .package: 3]
        toolchainItems = toolchainItems.enumerated().sorted {
            let left = actionOrder[$0.element.toolchain?.kind ?? .package] ?? 3
            let right = actionOrder[$1.element.toolchain?.kind ?? .package] ?? 3
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)

        var python: [RestoreItem] = []
        var applicationData: [RestoreItem] = []
        if components.contains(.python) {
            for environment in manifest.python.environments {
                let minor = environment.minorVersion
                var dependsOn: [String] = []
                // An environment based on a pyenv or uv Python waits for exactly that version when it is restored too.
                let exact = toolchainItems.first { item in
                    guard let action = item.toolchain, action.kind == .runtime, [.pyenv, .uv].contains(action.provider) else { return false }
                    return action.runtime?.version == environment.pythonVersion
                        && (environment.baseSource == .pyenv) == (action.provider == .pyenv)
                }
                if let exact {
                    dependsOn = [exact.id]
                } else {
                    let formulaName = PythonVersion.formula(forMinor: minor)
                    let runtimeID = "formula:\(formulaName)"
                    if !formulae.contains(where: { $0.id == runtimeID }) {
                        formulae.append(RestoreItem(
                            id: runtimeID, kind: .formula, title: "Python \(minor)", identifier: formulaName,
                            dependsOn: [RestoreItem.homebrewID], component: .python))
                    }
                    dependsOn = [runtimeID]
                }
                python.append(RestoreItem(
                    id: "python:\(environment.id)", kind: .pythonEnvironment, title: environment.name, identifier: environment.path,
                    originalVersion: environment.pythonVersion, architectures: environment.architectures,
                    dependsOn: dependsOn, component: .python, pythonEnvironment: environment))
            }
        }
        if components.contains(.developerSettings), manifest.developer.gitConfig != nil {
            var item = RestoreItem(id: "git:config", kind: .gitConfiguration, title: "Git", identifier: "~/.gitconfig",
                                   component: .developerSettings)
            item.gitConfig = manifest.developer.gitConfig
            applicationData.append(item)
        }
        if components.contains(.credentials) {
            for record in manifest.credentials {
                applicationData.append(RestoreItem(id: "credential:\(record.provider)", kind: .credential, title: record.provider.uppercased(),
                                                   identifier: record.vaultPath, component: .credentials))
            }
        }
        if components.contains(.applicationData) {
            for folder in manifest.applicationData {
                applicationData.append(RestoreItem(
                    id: "appdata:\(folder.id)", kind: .applicationData, title: folder.name, identifier: folder.displayPath,
                    component: .applicationData, applicationData: folder))
            }
        }

        if components.contains(.fonts) {
            files += manifest.fonts.map { fileItem($0, kind: .font, component: .fonts) }
        }
        if components.contains(.colorProfiles) {
            files += manifest.iccProfiles.map { fileItem($0, kind: .colorProfile, component: .colorProfiles) }
        }

        let excluded = selection.excludedItemIDs
        formulae.removeAll { excluded.contains($0.id) }
        casks.removeAll { excluded.contains($0.id) }
        appStore.removeAll { excluded.contains($0.id) }
        files.removeAll { excluded.contains($0.id) }
        python.removeAll { excluded.contains($0.id) }
        applicationData.removeAll { excluded.contains($0.id) }
        toolchainItems.removeAll { excluded.contains($0.id) }
        manualItems.removeAll { excluded.contains($0.id) }
        // A Python runtime is only needed while an environment still uses it.
        let neededRuntimes = Set(python.flatMap(\.dependsOn))
        formulae.removeAll { $0.component == .python && !neededRuntimes.contains($0.id) }
        // A manager or runtime from Homebrew is only needed while one of its steps is still selected.
        let neededByToolchains = Set(toolchainItems.flatMap(\.dependsOn))
        let toolchainComponents: Set<RestoreComponent?> = [.developerTools, .packageManagers]
        formulae.removeAll { toolchainComponents.contains($0.component) && !neededByToolchains.contains($0.id) }

        // Only keep taps that a remaining package needs.
        let neededTaps = Set((formulae + casks).flatMap(\.dependsOn).filter { $0.hasPrefix("tap:") })
        let tapItems = taps.values.filter { neededTaps.contains($0.id) }.sorted { $0.id < $1.id }

        var items: [RestoreItem] = []
        let needsHomebrew = !(formulae.isEmpty && casks.isEmpty && python.isEmpty)
        if needsHomebrew {
            items.append(RestoreItem(id: RestoreItem.commandLineToolsID, kind: .commandLineTools,
                                     title: "Xcode Command Line Tools", identifier: "xcode-select"))
            items.append(RestoreItem(id: RestoreItem.homebrewID, kind: .homebrew, title: "Homebrew", identifier: "brew",
                                     dependsOn: [RestoreItem.commandLineToolsID]))
        }
        items += tapItems
        items += formulae.sorted { $0.identifier < $1.identifier }
        items += casks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        items += toolchainItems
        items += python
        items += applicationData
        items += files
        // Guided installs come last: everything automatic runs first, then the user is asked to act.
        items += appStore.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        items += manualItems.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        manual.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return RestorePlan(items: items, manualApps: manual)
    }

    private func fileItem(_ record: FileRecord, kind: RestoreItemKind, component: RestoreComponent) -> RestoreItem {
        let prefix = kind == .font ? "font" : "icc"
        return RestoreItem(id: "\(prefix):\(record.domain.rawValue)/\(record.relativePath)", kind: kind,
                           title: record.fileName, identifier: record.relativePath, file: record, component: component)
    }
}
