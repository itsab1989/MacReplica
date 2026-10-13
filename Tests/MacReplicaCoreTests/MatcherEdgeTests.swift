import Foundation
import Testing
@testable import MacReplicaCore

/// Boundaries and tie-breaks of the cask matcher that the mutation run showed untested.
@Suite("Matching: edge cases")
struct MatcherEdgeTests {
    static func app(_ name: String, bundle: String? = nil, vendor: String? = nil, file: String? = nil) -> AppRecord {
        AppRecord(name: name, bundleIdentifier: bundle, path: "/Applications/\(file ?? name).app", vendor: vendor)
    }

    @Test func aCandidateExactlyAtTheMinimumScoreIsOffered() {
        // Display name only: 25 points = the minimum.
        let matcher = Matcher(catalog: CaskCatalog(casks: [CaskInfo(token: "suite-tools", names: ["Tool Suite", "Toolkit"], appArtifacts: ["Other.app"])]))
        guard case .needsDecision(let candidates) = matcher.match(Self.app("Tool Suite", file: "Different")) else {
            Issue.record("expected a candidate at the minimum score"); return
        }
        #expect(candidates.first?.score == Matcher.minimumScore)
        // The candidate is shown with the cask's first name.
        #expect(candidates.first?.name == "Tool Suite")
        // 20 points (token only) stay below it.
        let tokenOnly = Matcher(catalog: CaskCatalog(casks: [CaskInfo(token: "tool-suite", names: ["Something"], appArtifacts: ["Other.app"])]))
        if case .needsDecision(let found) = tokenOnly.match(Self.app("Tool Suite", file: "Different")), found.contains(where: { $0.kind == .cask }) {
            Issue.record("a token-only match must not be offered")
        }
    }

    @Test func candidatesAreOrderedByScoreThenToken() {
        let matcher = Matcher(catalog: CaskCatalog(casks: [
            CaskInfo(token: "zeta", names: ["Shared"], appArtifacts: ["Shared.app"]),
            CaskInfo(token: "alpha", names: ["Shared"], appArtifacts: ["Shared.app"]),
            CaskInfo(token: "beta", names: ["Other"], appArtifacts: ["Shared.app"], bundleIdentifiers: ["com.example.shared"]),
        ]))
        guard case .needsDecision(let candidates) = matcher.match(Self.app("Shared", bundle: "com.example.shared")) else {
            Issue.record("expected a decision"); return
        }
        // beta: artifact + bundle (110) first; then the equal ones (artifact + name = 85) alphabetically.
        #expect(candidates.map(\.token) == ["beta", "alpha", "zeta"])
        #expect(candidates[0].score > candidates[1].score)
        #expect(candidates[1].score == candidates[2].score)
    }

    @Test func formulaFallbackTakesTheFirstMatch() {
        let matcher = Matcher(catalog: CaskCatalog(casks: [], formulae: [
            FormulaInfo(name: "first-tool", aliases: ["mytool"]), FormulaInfo(name: "mytool"),
        ]))
        guard case .needsDecision(let candidates) = matcher.match(Self.app("MyTool")) else { Issue.record("expected a formula"); return }
        #expect(candidates.map(\.token) == ["first-tool"])
        #expect(candidates[0].kind == .formula)
    }

    @Test func confidenceNeedsTheArtifactPlusOneMoreSignal() {
        func candidate(_ evidence: [MatchEvidence], kind: MatchCandidate.Kind = .cask) -> MatchCandidate {
            MatchCandidate(kind: kind, token: "t", name: "T", homepage: nil, score: 0, evidence: evidence)
        }
        #expect(Matcher.isConfident(candidate([.appBundleName, .bundleIdentifier])))
        #expect(Matcher.isConfident(candidate([.appBundleName, .displayName])))
        #expect(Matcher.isConfident(candidate([.appBundleName, .tokenName])))
        #expect(!Matcher.isConfident(candidate([.appBundleName, .vendor])))
        #expect(!Matcher.isConfident(candidate([.appBundleName])))
        #expect(!Matcher.isConfident(candidate([.bundleIdentifier, .displayName, .tokenName])))
        #expect(!Matcher.isConfident(candidate([.appBundleName, .bundleIdentifier], kind: .formula)))
    }

    @Test func disabledCaskByBundleIdentifierAloneOrTwoOtherSignals() {
        let catalog = CaskCatalog(casks: [
            CaskInfo(token: "enabled", names: ["Viewer"], appArtifacts: ["Viewer.app"], bundleIdentifiers: ["com.example.viewer"]),
            CaskInfo(token: "first-gone", names: ["Unrelated"], appArtifacts: ["Elsewhere.app"], bundleIdentifiers: ["com.example.viewer"], disabled: true),
            CaskInfo(token: "second-gone", names: ["Unrelated"], appArtifacts: ["Elsewhere.app"], bundleIdentifiers: ["com.example.viewer"], disabled: true),
            CaskInfo(token: "photo-kit", names: ["Something else"], appArtifacts: ["Photo Kit.app"], disabled: true),
            CaskInfo(token: "display-thing", names: ["Display Thing"], appArtifacts: [], disabled: true),
        ])
        let matcher = Matcher(catalog: catalog)
        // The bundle identifier alone is enough; the first disabled cask wins, an enabled one never counts.
        #expect(matcher.disabledCask(for: Self.app("Viewer", bundle: "com.example.viewer"))?.token == "first-gone")
        // App bundle name + token (two signals) without a bundle identifier.
        #expect(matcher.disabledCask(for: Self.app("Photo Kit"))?.token == "photo-kit")
        // A package-only cask: token + name.
        #expect(matcher.disabledCask(for: Self.app("Display Thing", file: "DT"))?.token == "display-thing")
        // One signal is not enough.
        #expect(matcher.disabledCask(for: Self.app("Other", file: "Photo Kit")) == nil)
    }

    @Test func vendorWordsOfThreeLettersCount() {
        #expect(Matcher.vendorMatchesHomepage(vendor: "Zed Industries", homepage: "https://zed.dev/"))
        #expect(!Matcher.vendorMatchesHomepage(vendor: "QT Group", homepage: "https://qt.io/"), "two-letter words are too ambiguous")
        #expect(!Matcher.vendorMatchesHomepage(vendor: "The Software Inc", homepage: "https://software.com/"), "generic words are ignored")
        #expect(!Matcher.vendorMatchesHomepage(vendor: "Zed", homepage: nil))
        #expect(Matcher.slug("Visual Studio Code") == "visual-studio-code")
        #expect(Matcher.slug("  Leading & trailing!! ") == "leading-and-trailing")
    }
}
