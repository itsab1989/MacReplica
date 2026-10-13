import Foundation

/// Homebrew taps that an app's own developer documents as the way to install it, for apps that are not in Homebrew's
/// main catalog. Data, not code: every entry names its source. A suggested tap is only used after the user allows it
/// in the restore selection, like every other third-party tap.
public struct VendorTap: Sendable, Equatable {
    public var bundleIdentifiers: [String]
    public var tap: String
    public var remote: String
    /// Cask tokens (without the tap) by release channel; `stable` is used when the installed app shows no other channel.
    public var casks: [ReleaseChannel: String]
    public var evidence: String

    public func fullToken(for channel: ReleaseChannel?) -> String {
        "\(tap)/\(casks[channel ?? .stable] ?? casks[.stable] ?? "")"
    }
}

public enum VendorTaps {
    public static let researched = "2026-10-13"

    public static let all: [VendorTap] = [
        // ChromIQ: casks `chromiq` (stable) and `chromiq@beta`, Apple silicon and Intel, macOS 13+ (the tap's README).
        VendorTap(bundleIdentifiers: ["com.chromiq.app"], tap: "itsab1989/chromiq", remote: "https://github.com/itsab1989/homebrew-chromiq",
                  casks: [.stable: "chromiq", .beta: "chromiq@beta"],
                  evidence: "https://github.com/itsab1989/homebrew-chromiq"),
    ]

    /// Taps of the backup that MacReplica's own list documents for an app in it: they start allowed in the restore
    /// selection (the user can still switch them off). Only with the documented address – a backup that names the tap
    /// with another remote is treated like any third-party tap and stays off.
    public static func defaultEnabledTaps(_ manifest: Manifest) -> Set<String> {
        Set(manifest.brewTaps.compactMap { record -> String? in
            let name = record.name.lowercased()
            guard let vendor = all.first(where: { $0.tap == name }) else { return nil }
            guard record.remote == nil || record.remote?.lowercased() == vendor.remote.lowercased() else { return nil }
            return name
        })
    }

    public static func tap(for app: AppRecord) -> VendorTap? {
        guard let identifier = app.bundleIdentifier?.lowercased() else { return nil }
        return all.first { $0.bundleIdentifiers.contains { $0.lowercased() == identifier } }
    }
}

/// Graphical front ends for a package manager. They are ordinary apps: restoring one restores neither the package
/// manager nor its packages, which MacReplica handles on their own (Homebrew: formulae, casks and taps).
public struct PackageManagerFrontEnd: Sendable, Equatable {
    public enum Manager: String, Sendable { case homebrew }
    public var bundleIdentifiers: [String]
    public var manager: Manager
    public var evidence: String
}

public enum PackageManagerFrontEnds {
    public static let all: [PackageManagerFrontEnd] = [
        // Cakebrew: “Cakebrew does not install Homebrew” (cakebrew.com); bundle identifier from its Info.plist (v1.3).
        PackageManagerFrontEnd(bundleIdentifiers: ["com.brunophilipe.Cakebrew"], manager: .homebrew, evidence: "https://www.cakebrew.com/"),
        // Applite: bundle identifier from the cask's uninstall/zap paths.
        PackageManagerFrontEnd(bundleIdentifiers: ["dev.aerolite.Applite"], manager: .homebrew, evidence: "https://formulae.brew.sh/api/cask/applite.json"),
    ]

    public static func frontEnd(for app: AppRecord) -> PackageManagerFrontEnd? {
        guard let identifier = app.bundleIdentifier?.lowercased() else { return nil }
        return all.first { $0.bundleIdentifiers.contains { $0.lowercased() == identifier } }
    }
}
