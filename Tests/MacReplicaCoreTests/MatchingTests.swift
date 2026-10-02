import Foundation
import Testing
@testable import MacReplicaCore

@Suite("Homebrew matching")
struct MatchingTests {
    static let catalog = CaskCatalog(casks: [
        CaskInfo(token: "example-editor", names: ["Example Editor"], appArtifacts: ["Example Editor.app"],
                 bundleIdentifiers: ["com.example.editor"], homepage: "https://editor.example.com/"),
        CaskInfo(token: "orbit", names: ["Orbit"], appArtifacts: ["Orbit.app"], bundleIdentifiers: ["org.example.orbit"],
                 homepage: "https://orbit.example.org/"),
        CaskInfo(token: "orbit@esr", names: ["Orbit ESR"], appArtifacts: ["Orbit.app"], bundleIdentifiers: ["org.example.orbit"],
                 homepage: "https://orbit.example.org/"),
        CaskInfo(token: "quill", names: ["Quill"], appArtifacts: ["Quill Pro.app"], homepage: "https://quill.example.com/"),
        CaskInfo(token: "gone", names: ["Gone"], appArtifacts: ["Gone.app"], disabled: true),
        CaskInfo(token: "old-thing", names: ["Old Thing"], appArtifacts: ["Old Thing.app"], deprecated: true),
        CaskInfo(token: "other-app", names: ["Other"], appArtifacts: ["Different.app"], bundleIdentifiers: ["com.example.shared"]),
    ], formulae: [FormulaInfo(name: "ripgrep", aliases: ["rg"], homepage: "https://github.com/BurntSushi/ripgrep")])

    static func app(_ name: String, bundle: String? = nil, vendor: String? = nil) -> AppRecord {
        AppRecord(name: name, bundleIdentifier: bundle, path: "/Applications/\(name).app", vendor: vendor)
    }

    let matcher = Matcher(catalog: MatchingTests.catalog)

    @Test func uniqueMatchNeedsArtifactPlusSecondSignal() throws {
        guard case .unique(let candidate) = matcher.match(Self.app("Example Editor", bundle: "com.example.editor")) else {
            Issue.record("expected unique match"); return
        }
        #expect(candidate.token == "example-editor")
        #expect(candidate.evidence.contains(.appBundleName))
        #expect(candidate.evidence.contains(.bundleIdentifier))
        #expect(candidate.score == 60 + 50 + 25 + 20)
    }

    @Test func artifactAndNameWithoutBundleIDIsStillUnique() {
        if case .unique(let candidate) = matcher.match(Self.app("Example Editor")) {
            #expect(candidate.token == "example-editor")
        } else {
            Issue.record("expected unique match")
        }
    }

    @Test func variantsWithTheSameAppNeedADecision() {
        guard case .needsDecision(let candidates) = matcher.match(Self.app("Orbit", bundle: "org.example.orbit")) else {
            Issue.record("expected decision"); return
        }
        #expect(Set(candidates.map(\.token)) == ["orbit", "orbit@esr"])
        #expect(candidates.first?.token == "orbit", "higher score first")
    }

    @Test func weakSingleCandidateIsNeverAutomatic() {
        guard case .needsDecision(let candidates) = matcher.match(Self.app("Quill")) else {
            Issue.record("expected decision"); return
        }
        #expect(candidates.map(\.token) == ["quill"])
        #expect(!candidates[0].evidence.contains(.appBundleName))
    }

    @Test func bundleIDAloneIsNotEnoughForAutomaticUse() {
        guard case .needsDecision(let candidates) = matcher.match(Self.app("Unrelated", bundle: "com.example.shared")) else {
            Issue.record("expected decision"); return
        }
        #expect(candidates.map(\.token) == ["other-app"])
    }

    @Test func disabledCasksAreIgnoredAndDeprecatedArePenalized() {
        #expect(matcher.match(Self.app("Gone")) == .none)
        if case .needsDecision(let candidates) = matcher.match(Self.app("Old Thing")) {
            #expect(candidates[0].score == 60 + 25 + 20 - 10)
        } else {
            Issue.record("deprecated cask with artifact+name should not be automatic")
        }
    }

    @Test func noMatchWithoutEvidence() {
        #expect(matcher.match(Self.app("Completely Unknown", bundle: "com.nobody.app")) == .none)
    }

    @Test func formulaIsOnlyOfferedAsPossibility() {
        guard case .needsDecision(let candidates) = matcher.match(Self.app("ripgrep")) else {
            Issue.record("expected formula suggestion"); return
        }
        #expect(candidates == [MatchCandidate(kind: .formula, token: "ripgrep", name: "ripgrep",
                                              homepage: "https://github.com/BurntSushi/ripgrep", score: 20, evidence: [.tokenName])])
        #expect(candidates[0].restoreMethod == .homebrewFormula(name: "ripgrep"))
    }

    @Test func decideRequiresExactlyOneConfidentBestCandidate() {
        let strong = MatchCandidate(kind: .cask, token: "a", name: "A", homepage: nil, score: 105, evidence: [.appBundleName, .displayName])
        let weak = MatchCandidate(kind: .cask, token: "b", name: "B", homepage: nil, score: 25, evidence: [.displayName])
        let strongCompetitor = MatchCandidate(kind: .cask, token: "c", name: "C", homepage: nil, score: 60, evidence: [.appBundleName])
        #expect(Matcher.decide([strong]) == .unique(strong))
        #expect(Matcher.decide([strong, weak]) == .unique(strong))
        #expect(Matcher.decide([strong, strongCompetitor]) == .needsDecision([strong, strongCompetitor]))
        #expect(Matcher.decide([weak]) == .needsDecision([weak]))
        #expect(Matcher.decide([]) == .none)
        let formula = MatchCandidate(kind: .formula, token: "f", name: "F", homepage: nil, score: 200, evidence: [.appBundleName, .tokenName])
        #expect(!Matcher.isConfident(formula))
    }

    @Test func scoringWeights() {
        #expect(Matcher.score([.appBundleName]) == 60)
        #expect(Matcher.score([.bundleIdentifier]) == 50)
        #expect(Matcher.score([.displayName]) == 25)
        #expect(Matcher.score([.tokenName]) == 20)
        #expect(Matcher.score([.vendor]) == 5)
        #expect(Matcher.score([]) == 0)
    }

    @Test func normalizationAndSlugs() {
        #expect(Matcher.normalize("Visual Studio Code.app") == "visualstudiocode")
        #expect(Matcher.normalize("Café Ö") == "caféö")
        #expect(Matcher.slug("Visual Studio Code") == "visual-studio-code")
        #expect(Matcher.slug("Tom & Jerry!.app") == "tom-and-jerry")
        #expect(Matcher.slug("  Multiple   Spaces ") == "multiple-spaces")
        #expect(Matcher.slug("Notepad++") == "notepad++")
    }

    @Test func vendorMatchesHomepageHost() {
        #expect(Matcher.vendorMatchesHomepage(vendor: "Forgeworks Inc.", homepage: "https://www.forgeworks.com/app"))
        #expect(!Matcher.vendorMatchesHomepage(vendor: "Example Software Ltd", homepage: "https://other.org"))
        #expect(!Matcher.vendorMatchesHomepage(vendor: "Inc", homepage: "https://inc.com"))
        #expect(!Matcher.vendorMatchesHomepage(vendor: "Example", homepage: nil))
    }

    @Test func parsesPublicCaskJSON() throws {
        let json = #"""
        [{"token": "example-editor", "name": ["Example Editor", "EE"], "homepage": "https://editor.example.com/",
          "version": "1.2", "deprecated": false, "disabled": false,
          "depends_on": {"arch": [{"type": "arm", "bits": 64}]},
          "artifacts": [
            {"uninstall": [{"launchctl": "com.example.editor.helper", "quit": "com.example.editor"}]},
            {"app": ["Example Editor.app"], "target": "/Applications/Example Editor.app"},
            {"zap": [{"trash": ["~/Library/Preferences/com.example.editor.plist", "~/Library/Caches/com.example.editor.cache/",
                                "~/Library/Saved Application State/com.example.editor.savedState", "~/Library/Application Support/Editor",
                                "~/Library/Preferences/ByHost/com.example.editor.*.plist"]}]}
          ]},
         {"name": ["no token"]}]
        """#
        let casks = try CaskCatalog.parseCasks(Data(json.utf8))
        #expect(casks.count == 1)
        let cask = casks[0]
        #expect(cask.names == ["Example Editor", "EE"])
        #expect(cask.appArtifacts == ["Example Editor.app"])
        #expect(cask.bundleIdentifiers == ["com.example.editor", "com.example.editor.cache", "com.example.editor.helper"])
        #expect(cask.requiredArchitectures == [.arm64])
        #expect(throws: (any Error).self) { try CaskCatalog.parseCasks(Data("{}".utf8)) }
    }

    @Test func appArtifactsHonourTargetRenames() {
        let artifacts: [[String: Any]] = [["app": ["Source.app"], "target": "Renamed.app"], ["app": [["nested": true]]]]
        #expect(CaskCatalog.appArtifacts(from: artifacts) == ["Source.app", "Renamed.app"])
        #expect(CaskCatalog.appArtifacts(from: nil).isEmpty)
    }

    @Test func architectureRequirementFormats() {
        #expect(CaskCatalog.parseArchitectures([["type": "intel", "bits": 64]]) == [.x86_64])
        #expect(CaskCatalog.parseArchitectures("arm64") == [.arm64])
        #expect(CaskCatalog.parseArchitectures(["x86_64", "arm"]) == [.x86_64, .arm64])
        #expect(CaskCatalog.parseArchitectures(42).isEmpty)
    }

    @Test func bundleIdentifierValidation() {
        #expect(CaskCatalog.isBundleIdentifier("com.example.app"))
        #expect(!CaskCatalog.isBundleIdentifier("example.app"))
        #expect(!CaskCatalog.isBundleIdentifier("com.example.*"))
        #expect(!CaskCatalog.isBundleIdentifier("~/Library/x"))
    }

    @Test func parsesFormulaCatalog() throws {
        let formulae = try CaskCatalog.parseFormulae(Data(#"[{"name": "git", "aliases": ["git-scm"], "homepage": "https://git-scm.com"}, {}]"#.utf8))
        #expect(formulae == [FormulaInfo(name: "git", aliases: ["git-scm"], homepage: "https://git-scm.com")])
    }

    @Test func applyMatchesSetsMethodsConservatively() {
        var apps = [Self.app("Example Editor", bundle: "com.example.editor"), Self.app("Orbit", bundle: "org.example.orbit"),
                    Self.app("Quill"), Self.app("Nothing")]
        apps.append(AppRecord(name: "Store", path: "/Applications/Store.app", source: .appStore))
        InventoryService.applyMatches(matcher, to: &apps)
        #expect(apps[0].restoreMethod == .homebrewCask(token: "example-editor"))
        #expect(apps[0].homepage == "https://editor.example.com/")
        #expect(apps[1].restoreMethod == .officialDownload(url: "https://orbit.example.org/"))
        #expect(apps[1].candidates.count == 2)
        #expect(apps[2].restoreMethod == .officialDownload(url: "https://quill.example.com/"))
        #expect(apps[3].restoreMethod == .manual)
        #expect(apps[4].restoreMethod == .manual && apps[4].candidates.isEmpty)
    }

    @Test func installedCasksAreLinkedToApps() {
        var apps = [Self.app("Example Editor"), Self.app("Other")]
        InventoryService.linkCasks([BrewCaskRecord(token: "example-editor", version: "1", appArtifacts: ["example editor.app"])], to: &apps)
        #expect(apps[0].source == .homebrewCask(token: "example-editor"))
        #expect(apps[0].restoreMethod == .homebrewCask(token: "example-editor"))
        #expect(apps[1].source == .unknown)
    }

    @Test func webURLValidation() {
        #expect(InventoryService.isWebURL("https://example.com"))
        #expect(InventoryService.isWebURL("http://example.com/x"))
        #expect(!InventoryService.isWebURL("javascript:alert(1)"))
        #expect(!InventoryService.isWebURL("file:///etc/passwd"))
        #expect(!InventoryService.isWebURL("not a url"))
    }
}
