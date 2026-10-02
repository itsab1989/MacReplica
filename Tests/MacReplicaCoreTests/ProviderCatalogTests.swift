import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

@Suite("Provider catalog")
struct ProviderCatalogTests {
    static let english = Localizer.loadTable(language: .english, resourcesFolder: LocalizationResources.folder)

    @Test func everyProviderIsDocumentedLocalizedAndSafe() {
        let providers = AppDataCatalog.providers
        #expect(providers.count >= 15)
        #expect(Set(providers.map(\.id)).count == providers.count, "provider IDs are unique")
        for provider in providers {
            #expect(!provider.bundleIdentifiers.isEmpty, "\(provider.id) has bundle identifiers")
            #expect(!provider.evidence.isEmpty && provider.evidence.allSatisfy { $0.url.hasPrefix("https://") }, "\(provider.id) cites sources")
            #expect(provider.researchedOn == "2026-10-02")
            #expect(provider.status == .fixtureTested, "\(provider.id) is not claimed as verified with the real app")
            #expect(PathSafety.isSafeRelativePath(provider.base), "\(provider.id) base")
            #expect(!provider.base.hasPrefix("Library/Caches") && !provider.base.hasPrefix("Library/Keychains"))
            for category in provider.categories {
                #expect(category.classification.isOffered, "\(provider.id)/\(category.key) is offered")
                #expect(category.path.isEmpty || PathSafety.isSafeRelativePath(category.path), "\(provider.id)/\(category.key) path")
                #expect(Self.english["appData.category.\(category.key)"] != nil, "\(category.key) is localized")
            }
            if let pattern = provider.versionFolderPattern {
                #expect((try? NSRegularExpression(pattern: pattern)) != nil, "\(provider.id) pattern compiles")
            }
        }
        for entry in GuidanceCatalog.entries {
            #expect(!entry.evidence.isEmpty && entry.evidence.allSatisfy { $0.url.hasPrefix("https://") }, "\(entry.id) cites a source")
            #expect(!entry.bundleIdentifiers.isEmpty || !entry.paths.isEmpty, "\(entry.id) can be detected")
            if entry.kind == .manualMigration { #expect(Self.english["guidance.manual.\(entry.id)"] != nil, "\(entry.id) instructions") }
        }
        for provider in CredentialProviders.all {
            #expect(Self.english[provider.titleKey] != nil && Self.english[provider.descriptionKey] != nil && Self.english[provider.riskKey] != nil,
                    "\(provider.id) texts")
        }
    }

    @Test func versionPatternsMatchRealFolderNames() throws {
        func matches(_ id: String, _ name: String) throws -> Bool {
            let pattern = try #require(AppDataProviders.provider(id: id)?.versionFolderPattern)
            return name.range(of: pattern, options: .regularExpression) != nil
        }
        #expect(try matches("adobe-photoshop", "Adobe Photoshop 2026"))
        #expect(try !matches("adobe-photoshop", "Adobe Photoshop 2026 Settings"))
        #expect(try matches("adobe-photoshop-settings", "Adobe Photoshop 2026 Settings"))
        #expect(try matches("jetbrains", "IntelliJIdea2026.2"))
        #expect(try matches("jetbrains", "PyCharmCE2025.3"))
        #expect(try !matches("jetbrains", "consentOptions"))
        #expect(try matches("blender", "4.2"))
        #expect(try !matches("blender", "config"))
        #expect(try matches("sublime-text", "Sublime Text"))
        #expect(try matches("sublime-text", "Sublime Text 3"))
        #expect(try !matches("sublime-text", "Sublime Merge"))
    }

    @Test func detectionUsesOnlyTheDataNotTheInstalledApps() throws {
        let sandbox = try Sandbox("providers-detect")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        let detected = AppDataProviders.detect(layout: source.layout)
        let names = Set(detected.map { "\($0.profile.provider)/\($0.profile.category)" })
        #expect(names == ["adobe-photoshop/actions", "adobe-photoshop/brushes", "alfred/preferencesBundle", "blender/addons", "blender/preferences",
                          "davinci-resolve/fusionTemplates", "jetbrains/codeStyles", "jetbrains/keymaps", "keyboard-maestro/macros",
                          "sublime-text/userPackage", "vscode/settings", "vscode/snippets"])
        #expect(detected.first { $0.profile.provider == "vscode" && $0.profile.category == "settings" }?.files == ["settings.json", "keybindings.json"])
        #expect(detected.first { $0.profile.provider == "jetbrains" }?.profile.appVersion == "IntelliJIdea2026.2")
        // An empty Mac: nothing detected, nothing fails.
        let (_, fresh) = try TestEnvironment.freshMac(sandbox)
        #expect(AppDataProviders.detect(layout: fresh.layout).isEmpty)
    }

    @Test func malformedLocationsAreSkippedGracefully() throws {
        let sandbox = try Sandbox("providers-malformed")
        let (root, simulation) = try TestEnvironment.freshMac(sandbox)
        // A file where a folder is expected, and an empty folder.
        try sandbox.write("not a folder", to: "fresh/home/Library/Application Support/BBEdit/Clippings")
        try FileManager.default.createDirectory(at: root.url.appendingPathComponent("home/Library/Application Support/iTerm2/DynamicProfiles"),
                                                withIntermediateDirectories: true)
        #expect(AppDataProviders.detect(layout: simulation.layout).isEmpty)
    }

    @Test func onlyUserDataIsBackedUpNeverCachesOrMachineState() async throws {
        let sandbox = try Sandbox("providers-backup")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let backedUp = Set(manifest.applicationData.flatMap { folder in folder.files.map { folder.relativePath + "/" + $0.relativePath } })
        for expected in ["Library/Application Support/Code/User/settings.json", "Library/Application Support/Code/User/keybindings.json",
                         "Library/Application Support/Code/User/snippets/python.json",
                         "Library/Application Support/JetBrains/IntelliJIdea2026.2/keymaps/Synthetic.xml",
                         "Library/Application Support/Sublime Text/Packages/User/Preferences.sublime-settings",
                         "Library/Application Support/Sublime Text/Packages/User/Package Control.sublime-settings",
                         "Library/Application Support/Blender/4.2/config/userpref.blend"] {
            #expect(backedUp.contains(expected), "\(expected)")
        }
        for forbidden in ["state.vscdb", "CachedData", "jdk.table.xml", "plugins/", "Package Control.cache", "Package Control.last-run",
                          "License.sublime_license", "recent-files.txt", ".vscode/extensions"] {
            #expect(!backedUp.contains { $0.contains(forbidden) }, "\(forbidden) must not be backed up")
            #expect(!BackupWriter.allFiles(in: backup).contains { $0.contains(forbidden) }, "\(forbidden) not in package")
        }
        #expect(manifest.developer.editorExtensions == ["Visual Studio Code": ["esbenp.prettier-vscode", "ms-python.python"]])
        let guide = try String(contentsOf: backup.appendingPathComponent("restore/RESTORE_INSTRUCTIONS.html"), encoding: .utf8)
        #expect(guide.contains("code --install-extension ms-python.python"))
        // Default selection follows the classification.
        func classification(_ provider: String, _ category: String) -> DataClassification? {
            manifest.applicationData.first { $0.profile?.provider == provider && $0.profile?.category == category }?.profile?.classification
        }
        #expect(classification("vscode", "settings") == .safe)
        #expect(classification("blender", "addons") == .compatibilitySensitive)
        #expect(classification("alfred", "preferencesBundle") == .mayContainSecrets)
        #expect(classification("keyboard-maestro", "macros") == .mayContainSecrets)
        #expect(DataClassification.mayContainSecrets.selectedByDefault == false)
        #expect(DataClassification.compatibilitySensitive.selectedByDefault == false)
        #expect(DataClassification.safe.selectedByDefault)
        #expect(!DataClassification.cache.isOffered && !DataClassification.credential.isOffered && !DataClassification.database.isOffered)
    }

    @Test func appsThatMustBeClosedAreNotRestoredWhileRunning() async throws {
        let sandbox = try Sandbox("providers-running")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let vscode = try #require(manifest.applicationData.first { $0.profile?.provider == "vscode" && $0.profile?.category == "settings" })
        let plan = RestorePlan(items: RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.applicationData]))
            .items.filter { $0.id == "appdata:\(vscode.id)" }, manualApps: [])
        func run(running: Bool) async -> ItemResult? {
            var environment = TestEnvironment.restoreEnvironment(target)
            environment.isApplicationRunning = { $0 == "com.microsoft.VSCode" && running }
            return await RestoreExecutor(environment: environment, backupRoot: backup, sessionStore: nil)
                .run(plan: plan, session: RestoreSession(backupPath: "", selection: RestoreSelection(), itemIDs: plan.items.map(\.id)), onEvent: { _ in })
                .results.values.first
        }
        #expect(await run(running: true)?.outcome.label == "failed(applicationRunning)")
        #expect(!FileManager.default.fileExists(atPath: fresh.url.appendingPathComponent("home/Library/Application Support/Code/User/settings.json").path))
        #expect(await run(running: false)?.outcome == .succeeded)
        #expect(await run(running: false)?.outcome == .alreadyPresent, "idempotent")
    }

    @Test func versionedDataNotesAMissingAppVersion() async throws {
        let sandbox = try Sandbox("providers-version")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (_, target) = try TestEnvironment.freshMac(sandbox)
        let keymaps = try #require(manifest.applicationData.first { $0.profile?.provider == "jetbrains" && $0.profile?.category == "keymaps" })
        let plan = RestorePlan(items: RestorePlanner().plan(manifest: manifest, selection: RestoreSelection(components: [.applicationData]))
            .items.filter { $0.id == "appdata:\(keymaps.id)" }, manualApps: [])
        let result = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: RestoreSelection(), itemIDs: plan.items.map(\.id)), onEvent: { _ in })
            .results.values.first
        #expect(result?.outcome == .succeeded)
        #expect(result?.notes.contains(.applicationVersionDiffers(original: "IntelliJIdea2026.2")) == true)
    }

    @Test func oneDamagedProviderDoesNotAffectOthers() async throws {
        let sandbox = try Sandbox("providers-isolation")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let sublime = try #require(manifest.applicationData.first { $0.profile?.provider == "sublime-text" })
        try Data("tampered".utf8).write(to: backup.appendingPathComponent(sublime.files[0].backupPath))
        let (_, target) = try TestEnvironment.freshMac(sandbox)
        let selection = RestoreSelection(components: [.applicationData])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let session = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        #expect(session.results["appdata:\(sublime.id)"]?.outcome.isFailure == true)
        let others = session.results.filter { $0.key != "appdata:\(sublime.id)" }
        #expect(!others.isEmpty && others.values.allSatisfy { $0.outcome.isSuccessLike })
    }

    @Test func guidanceMarksServicesThatNeedANewSignIn() throws {
        let sandbox = try Sandbox("providers-guidance")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        let records = GuidanceDetector.detect(layout: source.layout, installedBundleIDs: ["com.tinyspeck.slackmacgap", "com.raycast.macos"])
        #expect(records.contains(GuidanceRecord(id: "githubCLI", name: "GitHub CLI", kind: .reauthenticationRequired)), "found by ~/.config/gh")
        #expect(records.contains(GuidanceRecord(id: "slack", name: "Slack", kind: .reauthenticationRequired)), "found by bundle identifier")
        #expect(records.contains(GuidanceRecord(id: "raycast", name: "Raycast", kind: .manualMigration)))
        #expect(!records.contains { $0.id == "dropbox" })
        let (_, fresh) = try TestEnvironment.freshMac(sandbox)
        #expect(GuidanceDetector.detect(layout: fresh.layout, installedBundleIDs: []).isEmpty)
    }

    @Test func inventoryRecordsGuidanceWithoutClaimingRestoredLogins() async throws {
        let sandbox = try Sandbox("providers-guidance-inventory")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        #expect(manifest.guidance.map(\.id) == ["githubCLI"])
        let guide = try String(contentsOf: backup.appendingPathComponent("restore/RESTORE_INSTRUCTIONS.html"), encoding: .utf8)
        #expect(guide.contains("Sign in again on the new Mac:") && guide.contains("GitHub CLI"))
        #expect(!guide.lowercased().contains("credentials restored"))
    }

    @Test func extensionIdentifiers() {
        #expect(DeveloperSettingsScanner.extensionID("ms-python.python-2024.1.0") == "ms-python.python")
        #expect(DeveloperSettingsScanner.extensionID("esbenp.prettier-vscode-10.4.0") == "esbenp.prettier-vscode")
        #expect(DeveloperSettingsScanner.extensionID("ms-vscode.cpptools-1.20.5-darwin-arm64") == "ms-vscode.cpptools")
        #expect(DeveloperSettingsScanner.extensionID("extensions.json") == nil)
        #expect(DeveloperSettingsScanner.extensionID(".obsolete") == nil)
    }
}

@Suite("File credential providers", .serialized)
struct FileCredentialProviderTests {
    @Test func detectionIsExactAndOptIn() throws {
        let sandbox = try Sandbox("cred-detect")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        let detected = Dictionary(uniqueKeysWithValues: CredentialProviders.all.map { ($0.id, $0.detect(layout: source.layout)) })
        #expect(detected["aws"] == [".aws/credentials", ".aws/config"])
        #expect(detected["npm"] == [".npmrc"])
        #expect(detected["gitCredentials"] == [])
        #expect(detected["kubernetes"] == [])
        #expect(detected["terraform"] == [])
        let aws = try #require(CredentialProviders.provider(id: "aws"))
        #expect(aws.destination(for: CredentialFile(name: ".aws/sso/cache/token.json", permissions: 0o600, contents: Data()), layout: source.layout) == nil,
                "SSO caches are never restored")
        #expect(aws.destination(for: CredentialFile(name: "../.aws/credentials", permissions: 0o600, contents: Data()), layout: source.layout) == nil)
        let (_, fresh) = try TestEnvironment.freshMac(sandbox)
        #expect(CredentialProviders.all.allSatisfy { $0.detect(layout: fresh.layout).isEmpty })
    }

    @Test func awsAndNpmRoundTripEncryptedAndPrivate() async throws {
        let sandbox = try Sandbox("cred-roundtrip")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        let result = try await TestEnvironment.inventory(source).run()
        let passphrase = "synthetic provider passphrase"
        let outcome = try BackupWriter(layout: source.layout, localizer: TestEnvironment.english)
            .write(result, into: try sandbox.folder("out"), log: LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory),
                   credentials: CredentialExportRequest(providerIDs: ["aws", "npm"], passphrase: passphrase))
        #expect(outcome.manifest.credentials.map(\.provider) == ["aws", "npm"])
        for path in BackupWriter.allFiles(in: outcome.url) where !path.hasPrefix("credentials/") {
            let text = (try? String(contentsOf: outcome.url.appendingPathComponent(path), encoding: .utf8)) ?? ""
            #expect(!text.contains("synthetic-secret") && !text.contains("synthetic-npm-token") && !text.contains(passphrase), "\(path)")
        }
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let selection = RestoreSelection(components: [.credentials])
        let plan = RestorePlanner().plan(manifest: outcome.manifest, selection: selection)
        #expect(plan.items.map(\.id) == ["credential:aws", "credential:npm"])
        var environment = TestEnvironment.restoreEnvironment(target)
        environment.credentialPassphrase = passphrase
        let session = await RestoreExecutor(environment: environment, backupRoot: outcome.url, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        #expect(session.results["credential:aws"]?.outcome == .succeeded)
        #expect(session.results["credential:npm"]?.outcome == .succeeded)
        let credentials = fresh.url.appendingPathComponent("home/.aws/credentials")
        #expect(try String(contentsOf: credentials, encoding: .utf8).contains("synthetic-secret"))
        #expect((try FileManager.default.attributesOfItem(atPath: credentials.path)[.posixPermissions] as? Int).map { $0 & 0o077 } == 0,
                "never readable by others")
        #expect((try FileManager.default.attributesOfItem(atPath: credentials.deletingLastPathComponent().path)[.posixPermissions] as? Int) == 0o700)
        #expect(FileManager.default.fileExists(atPath: fresh.url.appendingPathComponent("home/.npmrc").path))
    }
}
