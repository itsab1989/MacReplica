import Foundation

public enum MatchOutcome: Equatable, Sendable {
    /// Exactly one package fits and the evidence is strong enough to use it automatically.
    case unique(MatchCandidate)
    /// Several packages could fit, or a single one fits only weakly; the user decides.
    case needsDecision([MatchCandidate])
    case none
}

/// Finds Homebrew packages for applications that were not installed with Homebrew.
///
/// Matching is deliberately conservative: a package is only used automatically
/// when the app bundle name matches a cask artifact *and* a second, independent
/// signal (bundle identifier, product name or token) agrees, and no other cask
/// has comparable evidence. Everything else is presented to the user.
public struct Matcher: Sendable {
    public var catalog: CaskCatalog
    private let artifactIndex: [String: [Int]]
    private let bundleIndex: [String: [Int]]
    private let nameIndex: [String: [Int]]
    private let tokenIndex: [String: Int]

    public static let minimumScore = 25

    public init(catalog: CaskCatalog) {
        self.catalog = catalog
        var artifacts: [String: [Int]] = [:]
        var bundles: [String: [Int]] = [:]
        var names: [String: [Int]] = [:]
        var tokens: [String: Int] = [:]
        for (index, cask) in catalog.casks.enumerated() where !cask.disabled {
            for artifact in cask.appArtifacts { artifacts[artifact.lowercased(), default: []].append(index) }
            for identifier in cask.bundleIdentifiers { bundles[identifier.lowercased(), default: []].append(index) }
            for name in cask.names { names[Self.normalize(name), default: []].append(index) }
            tokens[cask.token.lowercased()] = index
        }
        artifactIndex = artifacts
        bundleIndex = bundles
        nameIndex = names
        tokenIndex = tokens
    }

    public func match(_ app: AppRecord) -> MatchOutcome {
        var evidence: [Int: Set<MatchEvidence>] = [:]
        let bundleName = app.bundleFileName.lowercased()
        for index in artifactIndex[bundleName] ?? [] { evidence[index, default: []].insert(.appBundleName) }
        if let identifier = app.bundleIdentifier?.lowercased() {
            for index in bundleIndex[identifier] ?? [] { evidence[index, default: []].insert(.bundleIdentifier) }
        }
        let normalizedName = Self.normalize(app.name)
        if !normalizedName.isEmpty {
            for index in nameIndex[normalizedName] ?? [] { evidence[index, default: []].insert(.displayName) }
        }
        if let index = tokenIndex[Self.slug(app.name)] { evidence[index, default: []].insert(.tokenName) }

        var candidates: [MatchCandidate] = []
        for (index, signals) in evidence {
            let cask = catalog.casks[index]
            var allSignals = signals
            if let vendor = app.vendor, Self.vendorMatchesHomepage(vendor: vendor, homepage: cask.homepage) {
                allSignals.insert(.vendor)
            }
            var score = Self.score(allSignals)
            if cask.deprecated { score -= 10 }
            guard score >= Self.minimumScore else { continue }
            candidates.append(MatchCandidate(
                kind: .cask, token: cask.token, name: cask.names.first ?? cask.token,
                homepage: cask.homepage, score: score,
                evidence: MatchEvidence.allCases.filter { allSignals.contains($0) }))
        }

        if candidates.isEmpty {
            // GUI apps are distributed as casks; a formula with exactly the app's name
            // is offered as a possibility but never chosen automatically.
            let slug = Self.slug(app.name)
            if let formula = catalog.formulae.first(where: { $0.name == slug || $0.aliases.contains(slug) }) {
                return .needsDecision([MatchCandidate(kind: .formula, token: formula.name, name: formula.name,
                                                      homepage: formula.homepage, score: Self.score([.tokenName]),
                                                      evidence: [.tokenName])])
            }
            return .none
        }

        candidates.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.token < rhs.token
        }
        let outcome = Self.decide(candidates)
        // A deprecated cask may disappear soon, so it is only ever used after the user confirms it.
        if case .unique(let candidate) = outcome, catalog.cask(token: candidate.token)?.deprecated == true {
            return .needsDecision(candidates)
        }
        return outcome
    }

    static func decide(_ candidates: [MatchCandidate]) -> MatchOutcome {
        guard let best = candidates.first else { return .none }
        let confident = candidates.filter(isConfident)
        let strongCompetitors = candidates.dropFirst().filter {
            $0.evidence.contains(.appBundleName) || $0.evidence.contains(.bundleIdentifier)
        }
        if confident.count == 1, confident[0] == best, strongCompetitors.isEmpty {
            return .unique(best)
        }
        return .needsDecision(candidates)
    }

    /// A candidate is confident when the app bundle name matches a cask artifact
    /// and at least one independent signal confirms it.
    static func isConfident(_ candidate: MatchCandidate) -> Bool {
        guard candidate.kind == .cask, candidate.evidence.contains(.appBundleName) else { return false }
        return candidate.evidence.contains(.bundleIdentifier)
            || candidate.evidence.contains(.displayName)
            || candidate.evidence.contains(.tokenName)
    }

    static func score(_ signals: Set<MatchEvidence>) -> Int {
        var score = 0
        if signals.contains(.appBundleName) { score += 60 }
        if signals.contains(.bundleIdentifier) { score += 50 }
        if signals.contains(.displayName) { score += 25 }
        if signals.contains(.tokenName) { score += 20 }
        if signals.contains(.vendor) { score += 5 }
        return score
    }

    /// Lowercases and strips everything but letters and digits: "Visual Studio Code" → "visualstudiocode".
    public static func normalize(_ value: String) -> String {
        var text = value.lowercased()
        if text.hasSuffix(".app") { text = String(text.dropLast(4)) }
        return String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Homebrew-style token: "Visual Studio Code" → "visual-studio-code".
    public static func slug(_ value: String) -> String {
        var text = value.lowercased()
        if text.hasSuffix(".app") { text = String(text.dropLast(4)) }
        text = text.replacingOccurrences(of: "&", with: " and ")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789+")
        var result = ""
        var lastWasDash = false
        for scalar in text.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }

    static func vendorMatchesHomepage(vendor: String, homepage: String?) -> Bool {
        guard let homepage, let host = URL(string: homepage)?.host?.lowercased() else { return false }
        let ignored: Set<String> = ["inc", "ltd", "llc", "gmbh", "corp", "corporation", "co", "the", "software", "limited", "ag", "sa", "bv"]
        let words = vendor.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !ignored.contains($0) }
        let hostLabels = host.split(separator: ".").map(String.init)
        return words.contains { word in hostLabels.contains(word) }
    }
}
