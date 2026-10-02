import Foundation

/// Metadata about one Homebrew cask, reduced to what matching needs.
public struct CaskInfo: Sendable, Equatable, Codable {
    public var token: String
    public var names: [String]
    public var appArtifacts: [String]
    public var bundleIdentifiers: [String]
    public var homepage: String?
    public var version: String?
    public var deprecated: Bool
    public var disabled: Bool
    /// Architectures the cask is limited to; empty means no restriction.
    public var requiredArchitectures: [CPUArchitecture]
    /// The vendor download Homebrew uses: the default (Apple silicon, newest macOS) plus per-platform overrides.
    public var download: CaskDownload?
    public var downloadVariations: [String: CaskDownload]
    /// Minimum macOS major version from `depends_on.macos`, e.g. `13`.
    public var minimumMacOS: String?

    public init(token: String, names: [String] = [], appArtifacts: [String] = [], bundleIdentifiers: [String] = [],
                homepage: String? = nil, version: String? = nil, deprecated: Bool = false, disabled: Bool = false,
                requiredArchitectures: [CPUArchitecture] = [], download: CaskDownload? = nil,
                downloadVariations: [String: CaskDownload] = [:], minimumMacOS: String? = nil) {
        self.download = download
        self.downloadVariations = downloadVariations
        self.minimumMacOS = minimumMacOS
        self.token = token
        self.names = names
        self.appArtifacts = appArtifacts
        self.bundleIdentifiers = bundleIdentifiers
        self.homepage = homepage
        self.version = version
        self.deprecated = deprecated
        self.disabled = disabled
        self.requiredArchitectures = requiredArchitectures
    }
}

/// A download as Homebrew's cask JSON describes it.
public struct CaskDownload: Sendable, Equatable, Codable, Hashable {
    public var url: String
    /// SHA-256 of the file; nil when the cask says `no_check` (the file changes with every release).
    public var sha256: String?
    /// The download needs browser-like request options (cookies, user agent); MacReplica sends the user to the website instead.
    public var needsBrowser: Bool

    public init(url: String, sha256: String?, needsBrowser: Bool = false) {
        self.url = url
        self.sha256 = sha256
        self.needsBrowser = needsBrowser
    }

    static func parse(_ object: [String: Any]?) -> CaskDownload? {
        guard let object, let url = object["url"] as? String, url.hasPrefix("https://") else { return nil }
        let sha = (object["sha256"] as? String).flatMap { $0.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil ? $0 : nil }
        let specs = object["url_specs"] as? [String: Any] ?? [:]
        return CaskDownload(url: url, sha256: sha, needsBrowser: specs["cookies"] != nil || specs["referer"] != nil || specs["user_agent"] != nil
                            || specs["data"] != nil || specs["header"] != nil)
    }
}

extension CaskInfo {
    /// Homebrew's platform key for a Mac: the macOS codename, prefixed with `arm64_` on Apple silicon.
    public static func platformKey(macOSVersion: String, architecture: CPUArchitecture) -> String? {
        let major = Int(macOSVersion.split(separator: ".").first ?? "") ?? 0
        let names = [13: "ventura", 14: "sonoma", 15: "sequoia", 26: "tahoe", 27: "golden_gate"]
        guard let name = names[major] else { return nil }
        return architecture == .x86_64 ? name : "arm64_" + name
    }

    /// The download for this Mac: the platform's override if there is one, else the default.
    public func download(macOSVersion: String, architecture: CPUArchitecture) -> CaskDownload? {
        if let key = Self.platformKey(macOSVersion: macOSVersion, architecture: architecture), let variation = downloadVariations[key] {
            return variation
        }
        // The default is built for Apple silicon; an Intel Mac needs an override unless the app is universal.
        return download
    }
}

public struct FormulaInfo: Sendable, Equatable, Codable {
    public var name: String
    public var aliases: [String]
    public var homepage: String?

    public init(name: String, aliases: [String] = [], homepage: String? = nil) {
        self.name = name
        self.aliases = aliases
        self.homepage = homepage
    }
}

/// The searchable Homebrew catalog used to find packages for apps that were installed manually.
public struct CaskCatalog: Sendable {
    public var casks: [CaskInfo]
    public var formulae: [FormulaInfo]

    public init(casks: [CaskInfo], formulae: [FormulaInfo] = []) {
        self.casks = casks
        self.formulae = formulae
    }

    public func cask(token: String) -> CaskInfo? {
        casks.first { $0.token == token }
    }

    /// Parses the public `https://formulae.brew.sh/api/cask.json` format.
    public static func parseCasks(_ data: Data) throws -> [CaskInfo] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw HomebrewError.unexpectedOutput("cask catalog")
        }
        return items.compactMap { item in
            guard let token = item["token"] as? String else { return nil }
            var architectures: [CPUArchitecture] = []
            var minimumMacOS: String?
            if let dependsOn = item["depends_on"] as? [String: Any] {
                if let arch = dependsOn["arch"] { architectures = parseArchitectures(arch) }
                if let macos = dependsOn["macos"] as? [String: Any], let values = macos[">="] as? [String] { minimumMacOS = values.first }
            }
            var variations: [String: CaskDownload] = [:]
            for (key, value) in item["variations"] as? [String: Any] ?? [:] {
                guard let object = value as? [String: Any], object["url"] != nil else { continue }
                // Overrides may change only the URL; the checksum then comes from the override as well or is unknown.
                variations[key] = CaskDownload.parse(object)
            }
            return CaskInfo(
                token: token,
                names: item["name"] as? [String] ?? [],
                appArtifacts: appArtifacts(from: item["artifacts"]),
                bundleIdentifiers: bundleIdentifiers(from: item["artifacts"]),
                homepage: item["homepage"] as? String,
                version: item["version"] as? String,
                deprecated: item["deprecated"] as? Bool ?? false,
                disabled: item["disabled"] as? Bool ?? false,
                requiredArchitectures: architectures,
                download: CaskDownload.parse(item),
                downloadVariations: variations,
                minimumMacOS: minimumMacOS)
        }
    }

    /// Parses the public `https://formulae.brew.sh/api/formula.json` format.
    public static func parseFormulae(_ data: Data) throws -> [FormulaInfo] {
        guard let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw HomebrewError.unexpectedOutput("formula catalog")
        }
        return items.compactMap { item in
            guard let name = item["name"] as? String else { return nil }
            return FormulaInfo(name: name, aliases: item["aliases"] as? [String] ?? [], homepage: item["homepage"] as? String)
        }
    }

    static func parseArchitectures(_ value: Any) -> [CPUArchitecture] {
        // Either [{"type": "arm", "bits": 64}] or a plain list/strings in older formats.
        let entries: [Any] = (value as? [Any]) ?? [value]
        var result: [CPUArchitecture] = []
        for entry in entries {
            var type: String?
            if let dict = entry as? [String: Any] { type = dict["type"] as? String } else { type = entry as? String }
            switch type?.lowercased() {
            case "arm", "arm64": result.append(.arm64)
            case "intel", "x86_64": result.append(.x86_64)
            default: break
            }
        }
        return result
    }

    /// `.app` names from the `artifacts` array of cask JSON.
    public static func appArtifacts(from artifacts: Any?) -> [String] {
        guard let list = artifacts as? [[String: Any]] else { return [] }
        var result: [String] = []
        for artifact in list {
            guard let apps = artifact["app"] as? [Any] else { continue }
            for app in apps {
                if let name = app as? String {
                    result.append((name as NSString).lastPathComponent)
                }
            }
            // Casks may rename the app on install via "target".
            if let target = artifact["target"] as? String, target.hasSuffix(".app") {
                let name = (target as NSString).lastPathComponent
                if !result.contains(name) { result.append(name) }
            }
        }
        return result
    }

    /// Bundle identifiers mentioned in `uninstall` and `zap` stanzas, for example
    /// `quit: com.example.editor` or `~/Library/Preferences/com.example.editor.plist`.
    public static func bundleIdentifiers(from artifacts: Any?) -> [String] {
        guard let list = artifacts as? [[String: Any]] else { return [] }
        var found = Set<String>()
        func addIdentifier(_ value: String) {
            let candidate = value.trimmingCharacters(in: .whitespaces)
            if isBundleIdentifier(candidate) { found.insert(candidate.lowercased()) }
        }
        func scanPath(_ path: String) {
            let patterns = [
                #"Preferences/(?:ByHost/)?([A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+){2,})\.plist"#,
                #"(?:Caches|HTTPStorages|Containers|WebKit|Application Scripts)/([A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+){2,})(?:/|$)"#,
                #"Saved Application State/([A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+){2,})\.savedState"#,
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(path.startIndex..., in: path)
                for match in regex.matches(in: path, range: range) {
                    if let r = Range(match.range(at: 1), in: path) { addIdentifier(String(path[r])) }
                }
            }
        }
        func visit(_ value: Any, key: String?) {
            if let string = value as? String {
                if ["quit", "signal", "launchctl", "login_item"].contains(key ?? "") {
                    addIdentifier(string)
                } else {
                    scanPath(string)
                }
            } else if let array = value as? [Any] {
                for element in array { visit(element, key: key) }
            } else if let dict = value as? [String: Any] {
                for (k, v) in dict { visit(v, key: k) }
            }
        }
        for artifact in list {
            for key in ["uninstall", "zap"] {
                if let stanza = artifact[key] { visit(stanza, key: nil) }
            }
        }
        return found.sorted()
    }

    static func isBundleIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+){2,}$"#, options: .regularExpression) != nil
            && !value.hasSuffix(".plist") && !value.contains("*")
    }
}

public protocol CatalogProviding: Sendable {
    func loadCatalog() async throws -> CaskCatalog
}

/// Loads the catalog from Homebrew's public JSON API and caches it for a day.
/// The data is only parsed, never executed.
public struct RemoteCatalogProvider: CatalogProviding {
    public static let caskURL = URL(string: "https://formulae.brew.sh/api/cask.json")!
    public static let formulaURL = URL(string: "https://formulae.brew.sh/api/formula.json")!

    public var cacheFolder: URL
    public var maxAge: TimeInterval

    public init(cacheFolder: URL, maxAge: TimeInterval = 24 * 3600) {
        self.cacheFolder = cacheFolder
        self.maxAge = maxAge
    }

    public func loadCatalog() async throws -> CaskCatalog {
        let caskData = try await cachedData(from: Self.caskURL, fileName: "cask.json")
        let formulaData = try? await cachedData(from: Self.formulaURL, fileName: "formula.json")
        let casks = try CaskCatalog.parseCasks(caskData)
        var formulae: [FormulaInfo] = []
        if let formulaData, let parsed = try? CaskCatalog.parseFormulae(formulaData) { formulae = parsed }
        return CaskCatalog(casks: casks, formulae: formulae)
    }

    private func cachedData(from url: URL, fileName: String) async throws -> Data {
        let cacheFile = cacheFolder.appendingPathComponent(fileName)
        let attributes = try? FileManager.default.attributesOfItem(atPath: cacheFile.path)
        if let modified = attributes?[.modificationDate] as? Date, Date().timeIntervalSince(modified) < maxAge,
           let data = try? Data(contentsOf: cacheFile) {
            return data
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw HomebrewError.unexpectedOutput("HTTP error for \(url.lastPathComponent)")
            }
            try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
            return data
        } catch {
            // Offline: an older cached copy is still better than no matching at all.
            if let data = try? Data(contentsOf: cacheFile) { return data }
            throw error
        }
    }
}

/// Loads catalog JSON files from a folder; used by tests and the simulation environment.
public struct LocalCatalogProvider: CatalogProviding {
    public var caskFile: URL
    public var formulaFile: URL?

    public init(caskFile: URL, formulaFile: URL? = nil) {
        self.caskFile = caskFile
        self.formulaFile = formulaFile
    }

    public func loadCatalog() async throws -> CaskCatalog {
        let casks = try CaskCatalog.parseCasks(Data(contentsOf: caskFile))
        var formulae: [FormulaInfo] = []
        if let formulaFile, let data = try? Data(contentsOf: formulaFile) {
            formulae = (try? CaskCatalog.parseFormulae(data)) ?? []
        }
        return CaskCatalog(casks: casks, formulae: formulae)
    }
}
