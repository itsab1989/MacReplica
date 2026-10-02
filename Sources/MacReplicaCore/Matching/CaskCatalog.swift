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

    public init(token: String, names: [String] = [], appArtifacts: [String] = [], bundleIdentifiers: [String] = [],
                homepage: String? = nil, version: String? = nil, deprecated: Bool = false, disabled: Bool = false,
                requiredArchitectures: [CPUArchitecture] = []) {
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
            if let dependsOn = item["depends_on"] as? [String: Any], let arch = dependsOn["arch"] {
                architectures = parseArchitectures(arch)
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
                requiredArchitectures: architectures)
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
