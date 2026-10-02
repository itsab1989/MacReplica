import Foundation
import Testing
@testable import MacReplicaCore

@Suite("Manifest")
struct ManifestTests {
    static func sample() -> Manifest {
        Manifest(
            macreplicaVersion: "1.0.0",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            macosVersion: "15.1.0",
            architecture: .arm64,
            homebrew: HomebrewSnapshot(version: "4.4.0", prefix: "/opt/homebrew"),
            applications: [
                AppRecord(name: "Example Editor", version: "1.2", bundleIdentifier: "com.example.editor",
                          path: "/Applications/Example Editor.app", vendor: "Example Ltd.", architectures: [.arm64, .x86_64],
                          source: .downloaded(agent: "Safari"), restoreMethod: .homebrewCask(token: "example-editor")),
                AppRecord(name: "Ledger", path: "/Applications/Ledger.app", source: .appStore, restoreMethod: .appStore(id: 42)),
                AppRecord(name: "Tool", path: "~/Applications/Tool.app", source: .package(identifier: "com.example.pkg"),
                          restoreMethod: .officialDownload(url: "https://example.com"),
                          candidates: [MatchCandidate(kind: .cask, token: "tool", name: "Tool", homepage: nil, score: 45, evidence: [.displayName, .tokenName])]),
            ],
            brewFormulae: [BrewFormulaRecord(name: "git", version: "2.47.0", tap: "homebrew/core")],
            brewCasks: [BrewCaskRecord(token: "example-editor", version: "1.2", appArtifacts: ["Example Editor.app"])],
            brewTaps: [BrewTapRecord(name: "example/tools", remote: "https://github.com/example/homebrew-tools")],
            masApps: [MASAppRecord(appStoreID: 42, name: "Ledger", version: "5.0", bundleIdentifier: "com.example.ledger")],
            fonts: [FileRecord(fileName: "A.otf", domain: .user, relativePath: "A.otf", originalPath: "~/Library/Fonts/A.otf",
                               backupPath: "fonts/user/A.otf", sha256: String(repeating: "a", count: 64), size: 10, metadata: ["family": "A"])],
            iccProfiles: [FileRecord(fileName: "P.icc", domain: .system, relativePath: "P.icc", originalPath: "/Library/ColorSync/Profiles/P.icc",
                                     backupPath: "icc_profiles/system/P.icc", sha256: String(repeating: "b", count: 64), size: 20)])
    }

    @Test func roundTripPreservesEverything() throws {
        let manifest = Self.sample()
        let decoded = try ManifestIO.decode(try ManifestIO.encode(manifest))
        #expect(decoded == manifest)
    }

    @Test func usesStableSnakeCaseKeys() throws {
        let json = String(decoding: try ManifestIO.encode(Self.sample()), as: UTF8.self)
        for key in ["\"manifest_version\"", "\"macos_version\"", "\"architecture\"", "\"macreplica_version\"", "\"applications\"",
                    "\"brew_formulae\"", "\"brew_casks\"", "\"mas_apps\"", "\"fonts\"", "\"icc_profiles\"", "\"app_store_id\"",
                    "\"bundle_identifier\"", "\"restore_method\"", "\"sha256\""] {
            #expect(json.contains(key), "missing \(key)")
        }
        #expect(json.contains("\"kind\" : \"homebrew_cask\""))
    }

    @Test func ignoresUnknownKeysFromNewerMinorVersions() throws {
        var object = try JSONSerialization.jsonObject(with: ManifestIO.encode(Self.sample())) as! [String: Any]
        object["future_section"] = ["anything": true]
        var apps = object["applications"] as! [[String: Any]]
        apps[0]["future_field"] = 1
        object["applications"] = apps
        let decoded = try ManifestIO.decode(JSONSerialization.data(withJSONObject: object))
        #expect(decoded.applications.count == 3)
    }

    @Test func missingSectionsAreTreatedAsEmpty() throws {
        let minimal = #"{"manifest_version": 1}"#
        let decoded = try ManifestIO.decode(Data(minimal.utf8))
        #expect(decoded.applications.isEmpty)
        #expect(decoded.fonts.isEmpty)
        #expect(decoded.architecture == .unknown)
        #expect(decoded.macreplicaVersion == "unknown")
    }

    @Test func unknownEnumValuesFallBackSafely() throws {
        let json = #"""
        {"manifest_version": 1, "architecture": "riscv64",
         "applications": [{"name": "X", "path": "/Applications/X.app",
                           "source": {"kind": "teleport"}, "restore_method": {"kind": "magic"}}]}
        """#
        let decoded = try ManifestIO.decode(Data(json.utf8))
        #expect(decoded.architecture == .unknown)
        #expect(decoded.applications[0].source == .unknown)
        #expect(decoded.applications[0].restoreMethod == .manual)
    }

    @Test func rejectsNewerMajorVersion() {
        #expect(throws: ManifestError.unsupportedVersion(found: 2, supported: 1)) {
            try ManifestIO.decode(Data(#"{"manifest_version": 2}"#.utf8))
        }
    }

    @Test func rejectsInvalidInput() {
        #expect(throws: ManifestError.unreadable("not valid JSON")) { try ManifestIO.decode(Data("{oops".utf8)) }
        #expect(throws: ManifestError.unreadable("top level is not an object")) { try ManifestIO.decode(Data("[1]".utf8)) }
        #expect(throws: ManifestError.unreadable("manifest_version is missing")) { try ManifestIO.decode(Data("{}".utf8)) }
        #expect(throws: ManifestError.invalid("manifest_version must be 1 or higher")) {
            try ManifestIO.decode(Data(#"{"manifest_version": 0}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try ManifestIO.decode(Data(#"{"manifest_version": 1, "applications": [{"name": 5}]}"#.utf8))
        }
    }

    @Test func migrationStepsRunInOrder() throws {
        let steps: [Int: @Sendable ([String: Any]) throws -> [String: Any]] = [
            1: { var d = $0; d["renamed"] = d["old"]; d["old"] = nil; return d },
            2: { var d = $0; d["added"] = true; return d },
        ]
        let result = try ManifestIO.migrate(["manifest_version": 1, "old": "value"], from: 1, steps: steps, targetVersion: 3)
        #expect(result["renamed"] as? String == "value")
        #expect(result["old"] == nil)
        #expect(result["added"] as? Bool == true)
        #expect(result["manifest_version"] as? Int == 3)
        #expect(throws: ManifestError.invalid("no migration from version 1")) {
            try ManifestIO.migrate(["manifest_version": 1], from: 1, steps: [:], targetVersion: 2)
        }
    }

    @Test func writeCreatesChecksumFile() throws {
        let sandbox = try Sandbox("manifest")
        try ManifestIO.write(Self.sample(), to: sandbox.url)
        let data = try Data(contentsOf: sandbox.url.appendingPathComponent("manifest.json"))
        let checksum = try String(contentsOf: sandbox.url.appendingPathComponent("manifest.json.sha256"), encoding: .utf8)
        #expect(checksum == Hashing.sha256Hex(of: data) + "  manifest.json\n")
        #expect(try ManifestIO.read(from: sandbox.url) == Self.sample())
        #expect(throws: ManifestError.unreadable("manifest.json not found")) { try ManifestIO.read(from: sandbox.url.appendingPathComponent("none")) }
    }

    @Test func needsMatchDecisionOnlyForUndecidedApps() {
        let candidate = MatchCandidate(kind: .cask, token: "t", name: "T", homepage: nil, score: 45, evidence: [.tokenName])
        #expect(AppRecord(name: "A", path: "/A.app", restoreMethod: .manual, candidates: [candidate]).needsMatchDecision)
        #expect(AppRecord(name: "A", path: "/A.app", restoreMethod: .officialDownload(url: "https://a"), candidates: [candidate]).needsMatchDecision)
        #expect(!AppRecord(name: "A", path: "/A.app", restoreMethod: .homebrewCask(token: "t"), candidates: [candidate]).needsMatchDecision)
        #expect(!AppRecord(name: "A", path: "/A.app", restoreMethod: .appStore(id: 1), candidates: [candidate]).needsMatchDecision)
        #expect(!AppRecord(name: "A", path: "/A.app", restoreMethod: .manual).needsMatchDecision)
    }

    @Test func builtInTapsAreRecognized() {
        #expect(BrewTapRecord(name: "homebrew/core").isBuiltIn)
        #expect(BrewTapRecord(name: "Homebrew/Cask").isBuiltIn)
        #expect(!BrewTapRecord(name: "example/tools").isBuiltIn)
    }

    @Test func versionComparisonIsNumeric() {
        #expect(VersionComparison.compare("1.10", "1.9") == .orderedDescending)
        #expect(VersionComparison.compare("2.4.0", "2.4.1") == .orderedAscending)
        #expect(VersionComparison.compare("3.0", "3") == .orderedSame)
        #expect(VersionComparison.compare("1.0b2", "1.0") == .orderedSame)
    }
}
