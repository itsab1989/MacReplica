import Foundation

/// A print queue of the old Mac: enough to set it up again, never the printer's settings database
/// (`/etc/cups/printers.conf` is readable only by root, and CUPS says not to edit it by hand).
public struct PrinterRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String { queue }
    /// The CUPS queue name, e.g. `Canon_PRO_300_`.
    public var queue: String
    /// How the Mac reaches the printer, e.g. `dnssd://Canon%20PRO-300…` (no credentials: user names and passwords are removed).
    public var deviceURI: String?
    public var manufacturer: String?
    /// The driver's name for the model, e.g. “Canon PRO-300 series” (PPD `*NickName`).
    public var model: String?
    public var driver: Driver
    /// Folders below `/Library/Printers` the driver uses (e.g. `Canon`), i.e. the vendor driver to install first.
    public var vendorDriverFolders: [String]
    /// The PPD in the backup (for reference only; it is not installed by MacReplica).
    public var ppd: FileRecord?

    public enum Driver: String, Codable, Sendable {
        /// AirPrint / IPP Everywhere: macOS sets the printer up without a vendor driver.
        case driverless
        /// A driver from the printer's manufacturer (in `/Library/Printers`); it must be installed again first.
        case vendor
        /// A driver that comes with macOS (e.g. generic PostScript or PCL).
        case builtIn
        case unknown

        public init(from decoder: Decoder) throws {
            self = Driver(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public init(queue: String, deviceURI: String?, manufacturer: String?, model: String?, driver: Driver, vendorDriverFolders: [String], ppd: FileRecord? = nil) {
        self.queue = queue
        self.deviceURI = deviceURI
        self.manufacturer = manufacturer
        self.model = model
        self.driver = driver
        self.vendorDriverFolders = vendorDriverFolders
        self.ppd = ppd
    }

    // "deviceUri" so that the snake_case key "device_uri" round-trips (the decoder would look for "deviceUri").
    private enum CodingKeys: String, CodingKey {
        case queue, manufacturer, model, driver, vendorDriverFolders, ppd
        case deviceURI = "deviceUri"
    }

    /// `dnssd`, `ipps`, `ipp`, `usb`, `lpd`, `socket`, `smb` … or nil.
    public var connection: String? { deviceURI.flatMap { URL(string: $0)?.scheme?.lowercased() } }
}

/// A scanner driver of a manufacturer (`/Library/Image Capture/Devices/*.app`), to install again on the new Mac.
public struct ScannerDriverRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: String { bundleIdentifier ?? name }
    public var name: String
    public var bundleIdentifier: String?
    public var version: String?

    public init(name: String, bundleIdentifier: String?, version: String?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
    }
}

/// Reads print queues and scanner drivers. Read-only: `lpstat -v` (no administrator rights) and the PPD files, which
/// every user may read. Nothing is changed.
public struct PrinterScanner: Sendable {
    public var layout: SystemLayout
    public var runner: CommandRunning

    public init(layout: SystemLayout, runner: CommandRunning) {
        self.layout = layout
        self.runner = runner
    }

    public func scan() async -> (printers: [PrinterRecord], ppdFiles: [ScannedFile], scanners: [ScannerDriverRecord]) {
        var uris: [String: String] = [:]
        // lpstat translates its output; C locale gives “device for <queue>: <uri>”.
        var environment = layout.processEnvironment(homebrewPrefix: nil, askpass: nil)
        environment["LC_ALL"] = "C"
        environment["LANG"] = "C"
        if let result = try? await runner.run(Command(executable: layout.lpstat, arguments: ["-v"], environment: environment, timeout: 30)), result.succeeded {
            uris = Self.parseDevices(result.stdout)
        }
        let ppds = ((try? FileManager.default.contentsOfDirectory(at: layout.cupsPPDFolder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "ppd" }
        var queues = Set(uris.keys)
        for ppd in ppds { queues.insert(ppd.deletingPathExtension().lastPathComponent) }
        var printers: [PrinterRecord] = []
        var files: [ScannedFile] = []
        for queue in queues.sorted() where Self.isSafeQueueName(queue) {
            let ppdURL = layout.cupsPPDFolder.appendingPathComponent("\(queue).ppd")
            let text = (try? String(contentsOf: ppdURL, encoding: .utf8)) ?? (try? String(contentsOf: ppdURL, encoding: .isoLatin1))
            let info = text.map(Self.parsePPD) ?? PPDInfo()
            var record = PrinterRecord(queue: queue, deviceURI: uris[queue].map(Self.withoutCredentials), manufacturer: info.manufacturer,
                                       model: info.nickName, driver: info.driver, vendorDriverFolders: info.vendorFolders)
            if text != nil, let sha = try? Hashing.sha256Hex(ofFile: ppdURL),
               let size = try? ppdURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                let file = FileRecord(fileName: "\(queue).ppd", domain: .system, relativePath: "\(queue).ppd", originalPath: layout.displayPath(ppdURL),
                                      backupPath: "printers/\(queue).ppd", sha256: sha, size: Int64(size))
                record.ppd = file
                files.append(ScannedFile(url: ppdURL, record: file))
            }
            printers.append(record)
        }
        return (printers, files, scannerDrivers())
    }

    func scannerDrivers() -> [ScannerDriverRecord] {
        let folder = layout.sharedLibrary.appendingPathComponent("Image Capture/Devices")
        let apps = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
        return apps.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { app in
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
            return ScannerDriverRecord(name: app.deletingPathExtension().lastPathComponent, bundleIdentifier: info["CFBundleIdentifier"] as? String,
                                       version: info["CFBundleShortVersionString"] as? String)
        }
    }

    /// CUPS queue names: letters, digits, `_`, `-`, `.`, `@` (no `/`, spaces or `#`).
    static func isSafeQueueName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_.@-]{1,127}$"#, options: .regularExpression) != nil
    }

    /// `lpstat -v` in the C locale: `device for Office_Laser: ipp://192.168.1.20/ipp/print`.
    static func parseDevices(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("device for "), let colon = line.range(of: ": ") else { continue }
            let queue = String(line[line.index(line.startIndex, offsetBy: 11)..<colon.lowerBound])
            result[queue] = String(line[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// Removes `user:password@` from a device URI.
    static func withoutCredentials(_ uri: String) -> String {
        guard var components = URLComponents(string: uri), components.user != nil || components.password != nil else { return uri }
        components.user = nil
        components.password = nil
        return components.string ?? uri
    }

    struct PPDInfo: Equatable {
        var manufacturer: String?
        var nickName: String?
        var driver: PrinterRecord.Driver = .unknown
        var vendorFolders: [String] = []
    }

    /// The few PPD keywords MacReplica needs: `*Manufacturer`, `*NickName`, and the filters (`*cupsFilter`, `*cupsFilter2`,
    /// `*APPrinterUtilityPath` …) that point into `/Library/Printers/<vendor>`.
    static func parsePPD(_ text: String) -> PPDInfo {
        var info = PPDInfo()
        var folders: [String] = []
        var airPrint = false
        for raw in text.split(whereSeparator: \.isNewline).prefix(20000) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            func value() -> String? {
                guard let range = line.range(of: ":") else { return nil }
                return line[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
            }
            if line.hasPrefix("*Manufacturer:") { info.manufacturer = value() }
            if line.hasPrefix("*NickName:") { info.nickName = value() }
            if line.hasPrefix("*APAirPrint") || line.hasPrefix("*cupsIPPSupplies") || line.contains("IPP Everywhere") { airPrint = true }
            if let range = line.range(of: "/Library/Printers/") {
                let rest = line[range.upperBound...]
                if let folder = rest.split(separator: "/").first.map(String.init), !folder.isEmpty, folder != "PPDs", !folders.contains(folder) {
                    folders.append(folder)
                }
            }
        }
        info.vendorFolders = folders
        if !folders.isEmpty { info.driver = .vendor } else if airPrint { info.driver = .driverless }
        else if info.nickName != nil { info.driver = .builtIn }
        return info
    }
}
