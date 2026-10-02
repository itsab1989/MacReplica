import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

@Suite("Version and updates")
struct VersionAndUpdateTests {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func versionHasOneSourceAndIsUsedEverywhere() throws {
        #expect(SemanticVersion(MacReplicaVersion.current) != nil, "the version is MAJOR.MINOR.PATCH")
        #expect(SystemInfo.appVersion == MacReplicaVersion.current)
        #expect(SystemInfo.buildNumber == "dev", "tests do not run inside the app bundle")
        // The bundle metadata is generated from the constant, never written by hand.
        let plist = try String(contentsOf: Self.repository.appendingPathComponent("Packaging/Info.plist"), encoding: .utf8)
        #expect(plist.contains("<string>__VERSION__</string>") && plist.contains("<string>__BUILD__</string>") && plist.contains("<string>__MINOS__</string>"))
        // The changelog's newest entry matches.
        let changelog = try String(contentsOf: Self.repository.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let newest = changelog.split(separator: "\n").first { $0.hasPrefix("## [") && !$0.contains("Unreleased") }
        #expect(newest?.contains("[\(MacReplicaVersion.current)]") == true)
        // Reports, logs and manifests carry the same version.
        #expect(ReportBuilder(localizer: TestEnvironment.english).inventoryReport(ManifestTests.sample()).contains(MacReplicaVersion.current))
    }

    @Test func manifestsRecordAppAndFormatVersionSeparately() async throws {
        let sandbox = try Sandbox("version-manifest")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        let manifest = try await TestEnvironment.inventory(source).run().manifest
        #expect(manifest.manifestVersion == Manifest.currentVersion)
        #expect(manifest.macreplicaVersion == MacReplicaVersion.current)
        #expect(manifest.macreplicaBuild == "dev")
        #expect(manifest.macosVersion == "15.1.0" && manifest.architecture == .arm64)
    }

    @Test func semanticVersionOrdering() throws {
        let order = ["0.9.9", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.10.0", "2.0.0"]
        let versions = try order.map { try #require(SemanticVersion($0)) }
        for (a, b) in zip(versions, versions.dropFirst()) { #expect(a < b, "\(a) < \(b)") }
        #expect(SemanticVersion("v1.2.3")?.description == "1.2.3")
        #expect(SemanticVersion("1.2.3+build.5") == SemanticVersion("1.2.3"))
        for bad in ["1.2", "x.y.z", "1.2.3.4", "", "-1.0.0"] { #expect(SemanticVersion(bad) == nil, "\(bad)") }
    }

    struct Fixed: ReleaseFetching {
        var result: Result<[ReleaseInfo], Error>
        func releases() async throws -> [ReleaseInfo] { try result.get() }
    }

    static func release(_ version: String, prerelease: Bool = false) -> ReleaseInfo {
        ReleaseInfo(version: version, pageURL: URL(string: "https://github.com/itsab1989/MacReplica/releases/tag/v\(version)")!, isPrerelease: prerelease)
    }

    @Test func updateStates() async {
        let newer = Self.release("1.1.0")
        let checker = UpdateChecker(fetcher: Fixed(result: .success([Self.release("1.0.0"), newer, Self.release("1.2.0-beta.1", prerelease: true)])))
        #expect(await checker.check(currentVersion: "1.0.0") == .available(release: newer, current: "1.0.0"))
        #expect(await checker.check(currentVersion: "1.1.0") == .upToDate(current: "1.1.0"))
        #expect(await checker.check(currentVersion: "1.1.0", includePrereleases: true)
                == .available(release: Self.release("1.2.0-beta.1", prerelease: true), current: "1.1.0"))
        #expect(await checker.check(currentVersion: "2.0.0") == .upToDate(current: "2.0.0"), "never suggests a downgrade")
        #expect(await UpdateChecker(fetcher: Fixed(result: .failure(URLError(.notConnectedToInternet)))).check(currentVersion: "1.0.0") == .unableToCheck)
        #expect(await UpdateChecker(fetcher: Fixed(result: .success([]))).check(currentVersion: "1.0.0") == .upToDate(current: "1.0.0"))
        #expect(await checker.check(currentVersion: "garbage") == .unableToCheck)
    }

    @Test func githubReleaseParsingIgnoresDraftsAndForeignPages() throws {
        let json = #"""
        [{"tag_name": "v1.1.0", "prerelease": false, "draft": false, "html_url": "https://github.com/itsab1989/MacReplica/releases/tag/v1.1.0"},
         {"tag_name": "v9.0.0", "draft": true, "html_url": "https://github.com/itsab1989/MacReplica/releases/tag/v9.0.0"},
         {"tag_name": "v5.0.0", "draft": false, "html_url": "https://evil.example.com/releases/v5"},
         {"tag_name": "nightly", "draft": false, "html_url": "https://github.com/itsab1989/MacReplica/releases/tag/nightly"},
         {"tag_name": "v1.2.0-rc.1", "prerelease": false, "draft": false, "html_url": "https://github.com/itsab1989/MacReplica/releases/tag/v1.2.0-rc.1"}]
        """#
        let releases = try GitHubReleaseFetcher.parse(Data(json.utf8))
        #expect(releases.map(\.version) == ["1.1.0", "1.2.0-rc.1"])
        #expect(releases[1].isPrerelease, "a pre-release tag counts as pre-release even if not flagged")
        #expect(throws: (any Error).self) { try GitHubReleaseFetcher.parse(Data("{}".utf8)) }
    }

    @Test func simulationReleaseDataDrivesTheCheck() async throws {
        let sandbox = try Sandbox("update-sim")
        let (root, _) = try TestEnvironment.freshMac(sandbox)
        let checker = UpdateChecker(fetcher: LocalReleaseFetcher(file: root.url.appendingPathComponent("releases/releases.json")))
        guard case .available(let release, _) = await checker.check(currentVersion: "1.0.0") else { Issue.record("expected update"); return }
        #expect(release.version == "1.1.0")
    }
}

@Suite("Permissions and locations")
struct PermissionTests {
    @Test func accessProbeDistinguishesStates() throws {
        let sandbox = try Sandbox("access")
        let readable = try sandbox.folder("readable")
        let blocked = try sandbox.folder("blocked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path) }
        #expect(AccessProbe.status(of: readable) == .scanned)
        #expect(AccessProbe.status(of: blocked) == .noPermission)
        #expect(AccessProbe.status(of: sandbox.url.appendingPathComponent("missing")) == .notFound)
        #expect(AccessProbe.status(of: try sandbox.write("x", to: "file")) == .unsupported)
        #expect(AccessProbe.fullDiskAccessSettingsURL.scheme == "x-apple.systempreferences")
    }

    @Test func inventoryContinuesAndReportsBlockedLocations() async throws {
        let sandbox = try Sandbox("access-inventory")
        let (root, simulation) = try TestEnvironment.sourceMac(sandbox)
        let systemFonts = root.url.appendingPathComponent("Library/Fonts")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: systemFonts.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: systemFonts.path) }
        try FileManager.default.removeItem(at: root.url.appendingPathComponent("home/Library/ColorSync/Profiles"))
        let manifest = try await TestEnvironment.inventory(simulation).run().manifest
        func status(_ area: AccessArea) -> AccessStatus? { manifest.locations.first { $0.area == area }?.status }
        #expect(status(.systemFonts) == .noPermission)
        #expect(status(.userColorProfiles) == .notFound)
        #expect(status(.userFonts) == .scanned)
        #expect(status(.homebrew) == .scanned)
        #expect(status(.appStore) == .scanned)
        #expect(manifest.fonts.count == 8, "everything readable is still included")
        let html = ReportBuilder(localizer: TestEnvironment.english).restoreInstructions(manifest, folderName: "x")
        #expect(html.contains("Locations that could not be read"))
        #expect(ReportBuilder(localizer: TestEnvironment.english).inventoryReport(manifest).contains("No permission"))
    }
}

@Suite("Application data profiles and developer settings")
struct ProviderTests {
    @Test func detectedDataIsBackedUpAndRestoredIntoTheVersionFolder() async throws {
        let sandbox = try Sandbox("profiles-restore")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let actions = try #require(manifest.applicationData.first { $0.profile?.category == "actions" })
        #expect(actions.name == "Adobe Photoshop 2025 · Actions")
        #expect(actions.files.map(\.relativePath) == ["My Actions.atn"])
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let selection = RestoreSelection(components: [.applicationData])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        let session = await RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
            .run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
        let result = try #require(session.results["appdata:\(actions.id)"])
        #expect(result.outcome == .succeeded)
        #expect(result.notes.contains(.applicationVersionDiffers(original: "Adobe Photoshop 2025")), "Photoshop 2025 is not installed on the fresh Mac")
        #expect(FileManager.default.fileExists(atPath: fresh.url.appendingPathComponent(
            "home/Library/Application Support/Adobe/Adobe Photoshop 2025/Presets/Actions/My Actions.atn").path))
    }

    @Test func gitConfigurationIsSanitized() throws {
        let sandbox = try Sandbox("git")
        let (_, simulation) = try TestEnvironment.sourceMac(sandbox)
        let withoutEmail = DeveloperSettingsScanner(layout: simulation.layout).scan(includeEmail: false)
        let text = try #require(withoutEmail.gitConfig)
        #expect(text.contains("name = Example Person"))
        #expect(text.contains("co = checkout"))
        #expect(text.contains("defaultBranch = main"))
        #expect(text.contains("helper = osxkeychain"))
        #expect(text.contains("excludesfile = ~/.gitignore_global"), "home folder is written as ~")
        for secret in ["person@example.com", "signingkey", "ghp_", "proxy", "secret", "git.example.internal", "insteadOf", "[url", "[http", "[github"] {
            #expect(!text.contains(secret), "\(secret) must be removed")
        }
        #expect(withoutEmail.removedGitSections == ["credential", "github", "http", "url"])
        #expect(!withoutEmail.gitConfigIncludesEmail)
        let withEmail = DeveloperSettingsScanner(layout: simulation.layout).scan(includeEmail: true)
        #expect(withEmail.gitConfig?.contains("email = person@example.com") == true)
        #expect(withEmail.gitConfigIncludesEmail)
    }

    @Test func gitConfigurationRestoreRespectsExistingFiles() async throws {
        let sandbox = try Sandbox("git-restore")
        let (backup, manifest) = try await TestEnvironment.makeBackup(sandbox)
        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let selection = RestoreSelection(components: [.developerSettings])
        let plan = RestorePlanner().plan(manifest: manifest, selection: selection)
        #expect(plan.items.map(\.id) == ["git:config"])
        let executor = RestoreExecutor(environment: TestEnvironment.restoreEnvironment(target), backupRoot: backup, sessionStore: nil)
        func run(_ selection: RestoreSelection) async -> ItemResult? {
            await executor.run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: ["git:config"]), onEvent: { _ in })
                .results["git:config"]
        }
        #expect(await run(selection)?.outcome == .succeeded)
        let gitconfig = fresh.url.appendingPathComponent("home/.gitconfig")
        #expect(try String(contentsOf: gitconfig, encoding: .utf8) == manifest.developer.gitConfig)
        #expect(await run(selection)?.outcome == .alreadyPresent)
        try Data("[user]\n\tname = Someone Else\n".utf8).write(to: gitconfig)
        #expect(await run(selection)?.outcome == .skipped(.keptExisting))
        var replace = selection
        replace.conflictResolution = .replace
        #expect(await run(replace)?.outcome == .succeeded)
        #expect(try String(contentsOf: gitconfig, encoding: .utf8) == manifest.developer.gitConfig)
    }
}

@Suite("Credentials", .serialized)
struct CredentialTests {
    static let files = [CredentialFile(name: "id_ed25519", permissions: 0o600, contents: Data("synthetic-secret-key".utf8))]

    @Test func vaultRoundTripAndRejection() throws {
        let sealed = try CredentialVault.seal(Self.files, passphrase: "correct horse battery", iterations: 100_000)
        #expect(String(decoding: sealed, as: UTF8.self).contains("AES-256-GCM"))
        #expect(!String(decoding: sealed, as: UTF8.self).contains("synthetic-secret-key"))
        #expect(sealed.range(of: Data("synthetic-secret-key".utf8)) == nil)
        #expect(try CredentialVault.open(sealed, passphrase: "correct horse battery") == Self.files)
        #expect(throws: CredentialError.wrongPassphraseOrDamaged) { try CredentialVault.open(sealed, passphrase: "wrong passphrase!!") }
        var envelope = try JSONSerialization.jsonObject(with: sealed) as! [String: Any]
        var bytes = Data(base64Encoded: envelope["sealed"] as! String)!
        bytes[bytes.count / 2] ^= 0x01
        envelope["sealed"] = bytes.base64EncodedString()
        #expect(throws: CredentialError.wrongPassphraseOrDamaged) {
            try CredentialVault.open(JSONSerialization.data(withJSONObject: envelope), passphrase: "correct horse battery")
        }
        envelope["iterations"] = 10
        #expect(throws: CredentialError.unsupportedFormat) {
            try CredentialVault.open(JSONSerialization.data(withJSONObject: envelope), passphrase: "correct horse battery")
        }
        #expect(throws: CredentialError.passphraseTooShort) { try CredentialVault.seal(Self.files, passphrase: "short") }
        #expect(throws: CredentialError.unsupportedFormat) { try CredentialVault.open(Data("{}".utf8), passphrase: "correct horse battery") }
        // Each seal uses a fresh salt and nonce.
        #expect(try CredentialVault.seal(Self.files, passphrase: "correct horse battery", iterations: 100_000) != sealed)
    }

    @Test func sshProviderSelectsOnlyKeysAndConfig() throws {
        let sandbox = try Sandbox("ssh-detect")
        let (_, simulation) = try TestEnvironment.sourceMac(sandbox)
        let provider = SSHKeyProvider()
        #expect(provider.detect(layout: simulation.layout) == ["config", "id_ed25519", "id_ed25519.pub", "known_hosts"])
        let exported = try provider.export(layout: simulation.layout)
        #expect(exported.first { $0.name == "id_ed25519" }?.permissions == 0o600)
        #expect(provider.destination(for: CredentialFile(name: "../evil", permissions: 0o600, contents: Data()), layout: simulation.layout) == nil)
        #expect(provider.destination(for: CredentialFile(name: "authorized_keys", permissions: 0o600, contents: Data()), layout: simulation.layout) == nil)
    }

    @Test func credentialsAreOptInEncryptedAndRestoredPrivately() async throws {
        let sandbox = try Sandbox("ssh-roundtrip")
        let (_, source) = try TestEnvironment.sourceMac(sandbox)
        let result = try await TestEnvironment.inventory(source).run()
        let log = LogStore(fileURL: nil, homeDirectory: source.layout.homeDirectory)
        let writer = BackupWriter(layout: source.layout, localizer: TestEnvironment.english)

        // Default: no credentials anywhere.
        let plain = try writer.write(result, into: try sandbox.folder("plain"), log: log)
        #expect(plain.manifest.credentials.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: plain.url.appendingPathComponent("credentials").path))

        // Explicit opt-in.
        let passphrase = "synthetic test passphrase"
        let outcome = try writer.write(result, into: try sandbox.folder("secure"), log: log,
                                       credentials: CredentialExportRequest(providerIDs: ["ssh"], passphrase: passphrase))
        let record = try #require(outcome.manifest.credentials.first)
        #expect(record.vaultPath == "credentials/ssh.macreplica-vault")
        #expect(record.items == ["config", "id_ed25519", "id_ed25519.pub", "known_hosts"])
        // No secret and no passphrase in plain files, reports or logs.
        for path in BackupWriter.allFiles(in: outcome.url) where !path.hasPrefix("credentials/") {
            let text = (try? String(contentsOf: outcome.url.appendingPathComponent(path), encoding: .utf8)) ?? ""
            #expect(!text.contains("synthetic-test-key-not-real"), "\(path)")
            #expect(!text.contains(passphrase), "\(path)")
        }
        #expect(!log.allLines.joined().contains(passphrase))
        #expect(BackupVerifier(layout: source.layout).verify(backupAt: outcome.url).isIntact)

        // Not part of a default restore, but offered so the user can switch it on.
        #expect(!RestoreSelection().components.contains(.credentials))
        #expect(RestorePlanner().candidateItems(manifest: outcome.manifest, selection: RestoreSelection()).contains { $0.id == "credential:ssh" })
        #expect(!RestorePlanner().plan(manifest: outcome.manifest, selection: RestoreSelection()).items.contains { $0.kind == .credential })

        let (fresh, target) = try TestEnvironment.freshMac(sandbox)
        let selection = RestoreSelection(components: [.credentials])
        let plan = RestorePlanner().plan(manifest: outcome.manifest, selection: selection)
        #expect(plan.items.map(\.id) == ["credential:ssh"])
        func restore(_ passphrase: String?, _ selection: RestoreSelection = RestoreSelection(components: [.credentials])) async -> ItemResult? {
            var environment = TestEnvironment.restoreEnvironment(target)
            environment.credentialPassphrase = passphrase
            return await RestoreExecutor(environment: environment, backupRoot: outcome.url, sessionStore: nil)
                .run(plan: plan, session: RestoreSession(backupPath: "", selection: selection, itemIDs: plan.items.map(\.id)), onEvent: { _ in })
                .results["credential:ssh"]
        }
        #expect(await restore(nil)?.outcome == .skipped(.passphraseNotProvided))
        #expect(await restore("wrong passphrase value")?.outcome.label == "failed(credentialCannotBeOpened)")
        #expect(!FileManager.default.fileExists(atPath: fresh.url.appendingPathComponent("home/.ssh").path), "nothing written on failure")
        #expect(await restore(passphrase)?.outcome == .succeeded)
        let key = fresh.url.appendingPathComponent("home/.ssh/id_ed25519")
        #expect(try String(contentsOf: key, encoding: .utf8).contains("synthetic-test-key-not-real"))
        #expect((try FileManager.default.attributesOfItem(atPath: key.path)[.posixPermissions] as? Int) == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: key.deletingLastPathComponent().path)[.posixPermissions] as? Int) == 0o700)
        #expect(await restore(passphrase)?.outcome == .alreadyPresent)
        // An existing, different key is kept unless the user chose to replace.
        try Data("another key".utf8).write(to: key)
        let kept = await restore(passphrase)
        #expect(kept?.notes == [.applicationDataCopied(copied: 0, identical: 3, kept: 1)])
        #expect(try String(contentsOf: key, encoding: .utf8) == "another key")
        var replace = selection
        replace.conflictResolution = .replace
        #expect(await restore(passphrase, replace)?.outcome == .succeeded)
        #expect(try String(contentsOf: key, encoding: .utf8).contains("synthetic-test-key-not-real"))
    }

    @Test func instructionsExplainSignInsAndKeychain() {
        let html = ReportBuilder(localizer: TestEnvironment.english).restoreInstructions(ManifestTests.sample(), folderName: "x")
        #expect(html.contains("Sign-ins and credentials"))
        #expect(html.contains("Keychain is never copied"))
        #expect(html.contains("This backup contains no credentials."))
    }
}
