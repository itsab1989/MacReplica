import Foundation

/// The Mac the reinstall guide is written for.
public struct MacProfile: Sendable, Equatable {
    public enum Family: String, Sendable { case appleSilicon, intelT2, intel }

    public var architecture: CPUArchitecture
    /// `hw.model`, e.g. `MacBookPro16,1`; nil if unknown.
    public var modelIdentifier: String?
    public var macOSVersion: String

    public init(architecture: CPUArchitecture, modelIdentifier: String?, macOSVersion: String) {
        self.architecture = architecture
        self.modelIdentifier = modelIdentifier
        self.macOSVersion = macOSVersion
    }

    /// Intel Macs with the Apple T2 Security Chip (Apple: “Mac computers that have the Apple T2 Security Chip”,
    /// https://support.apple.com/en-us/103265), by model identifier.
    static let t2Models: Set<String> = ["iMacPro1,1", "iMac20,1", "iMac20,2", "Macmini8,1", "MacPro7,1",
                                        "MacBookAir8,1", "MacBookAir8,2", "MacBookAir9,1",
                                        "MacBookPro15,1", "MacBookPro15,2", "MacBookPro15,3", "MacBookPro15,4",
                                        "MacBookPro16,1", "MacBookPro16,2", "MacBookPro16,3", "MacBookPro16,4"]

    public var family: Family {
        if architecture == .arm64 { return .appleSilicon }
        return modelIdentifier.map { Self.t2Models.contains($0) } == true ? .intelT2 : .intel
    }

    /// “Erase All Content and Settings” needs macOS 12 or later on Apple silicon or a Mac with the T2 chip.
    public var hasEraseAllContentAndSettings: Bool {
        family != .intel && VersionComparison.compare(macOSVersion, "12") != .orderedAscending
    }
}

/// Apple's support pages the guide links to (titles and addresses checked on 2026-10-13).
public enum AppleSupportLinks {
    public static let reinstall = "https://support.apple.com/en-us/102655"
    public static let recovery = "https://support.apple.com/en-us/102518"
    public static let startupKeys = "https://support.apple.com/en-us/102603"
    public static let eraseAllContent = "https://support.apple.com/en-us/102664"
    public static let eraseAppleSilicon = "https://support.apple.com/en-us/102506"
    public static let eraseIntel = "https://support.apple.com/en-us/102639"
    public static let bootableInstaller = "https://support.apple.com/en-us/101578"
    public static let startupSecurityUtility = "https://support.apple.com/en-us/102522"
    public static let downloadMacOS = "https://support.apple.com/en-us/102662"
    public static let t2Macs = "https://support.apple.com/en-us/103265"
    public static let compatibilityTahoe = "https://support.apple.com/en-us/122867"
    public static let compatibilitySequoia = "https://support.apple.com/en-us/120282"
    public static let compatibilitySonoma = "https://support.apple.com/en-us/105113"
}

/// A printable guide for reinstalling macOS on this Mac and bringing everything back with MacReplica
/// (`restore/REINSTALL_MACOS.html` in every backup). It states only what Apple documents for this kind of Mac and
/// never claims which macOS versions the Mac can install; it links Apple's compatibility pages instead.
extension ReportBuilder {
    public func reinstallGuide(profile: MacProfile, manifest: Manifest?, backupFolderName: String?) -> String {
        let l = localizer
        func h2(_ number: Int, _ key: String) -> String { "<h2>\(number). \(HTML.escape(l.t(key)))</h2>" }
        func p(_ text: String, _ cls: String? = nil) -> String { "<p\(cls.map { " class=\"\($0)\"" } ?? "")>\(HTML.escape(text))</p>" }
        func list(_ items: [String], ordered: Bool = false) -> String {
            let tag = ordered ? "ol" : "ul"
            return "<\(tag)>" + items.map { "<li>\(HTML.escape($0))</li>" }.joined() + "</\(tag)>"
        }
        func link(_ url: String, _ key: String) -> String { "<li>" + HTML.link(url, label: l.t(key)) + "</li>" }

        var body = ""
        // Warning first: nothing is erased before the backup is checked.
        body += "<p class=\"bad\"><b>\(HTML.escape(l.t("reinstall.warning")))</b></p>"

        body += h2(1, "reinstall.preflight.title")
        var preflight = [l.t("reinstall.preflight.power"), l.t("reinstall.preflight.network"), l.t("reinstall.preflight.account"),
                         l.t("reinstall.preflight.licences"), l.t("reinstall.preflight.drive")]
        if profile.family != .appleSilicon { preflight.append(l.t("reinstall.preflight.firmwarePassword")) }
        body += list(preflight)

        body += h2(2, "reinstall.backup.title")
        if let manifest {
            body += p(l.completenessTitle(manifest) + " " + l.completenessMessage(manifest), manifest.completeness == .partial ? "warn" : "ok")
            if let app = manifest.bootstrapApp {
                // The copy must run on this very Mac (a release build runs on both processors).
                let runsHere = app.runs(on: profile.architecture)
                body += p(l.bootstrapSummary(app) + (runsHere ? "" : " " + l.t("bootstrap.notThisMac")), runsHere ? "ok" : "bad")
            } else {
                body += p(l.t("bootstrap.missing"), "warn")
            }
        }
        body += list([l.t("reinstall.backup.verify"), l.t("reinstall.backup.secondCopy"), l.t("reinstall.backup.manual")])

        body += h2(3, "reinstall.mac.title")
        let model = profile.modelIdentifier.map { " (\($0))" } ?? ""
        body += p(l.t("reinstall.mac.\(profile.family.rawValue)", profile.macOSVersion) + model)
        body += p(l.t("reinstall.mac.compatibility"))
        body += "<ul>" + link(AppleSupportLinks.compatibilityTahoe, "reinstall.link.tahoe") + link(AppleSupportLinks.compatibilitySequoia, "reinstall.link.sequoia")
            + link(AppleSupportLinks.compatibilitySonoma, "reinstall.link.sonoma") + link(AppleSupportLinks.downloadMacOS, "reinstall.link.download") + "</ul>"

        body += h2(4, "reinstall.choose.title")
        var choices = [l.t("reinstall.choose.keep"), l.t("reinstall.choose.erase")]
        if profile.hasEraseAllContentAndSettings { choices.insert(l.t("reinstall.choose.eraseAll"), at: 1) }
        choices.append(l.t("reinstall.choose.bootable"))
        body += list(choices)

        body += h2(5, "reinstall.startup.title")
        switch profile.family {
        case .appleSilicon:
            body += list([l.t("reinstall.startup.as.1"), l.t("reinstall.startup.as.2"), l.t("reinstall.startup.as.3")], ordered: true)
        case .intel, .intelT2:
            body += list([l.t("reinstall.startup.intel.1"), l.t("reinstall.startup.intel.cmdR"), l.t("reinstall.startup.intel.optCmdR"),
                          l.t("reinstall.startup.intel.shiftOptCmdR"), l.t("reinstall.startup.intel.release")])
            if profile.family == .intelT2 { body += p(l.t("reinstall.startup.t2"), "warn") }
        }

        body += h2(6, "reinstall.erase.title")
        body += p(l.t("reinstall.erase.warning"), "bad")
        body += list([l.t("reinstall.erase.1"), l.t("reinstall.erase.2"), l.t("reinstall.erase.3")], ordered: true)

        body += h2(7, "reinstall.install.title")
        body += list([l.t("reinstall.install.1"), l.t("reinstall.install.2"), l.t("reinstall.install.3")], ordered: true)

        body += h2(8, "reinstall.firstBoot.title")
        body += list([l.t("reinstall.firstBoot.1"), l.t("reinstall.firstBoot.2"), l.t("reinstall.firstBoot.3"), l.t("reinstall.firstBoot.4")], ordered: true)

        body += h2(9, "reinstall.macreplica.title")
        body += list([manifest?.bootstrapApp == nil ? l.t("guide.newMac.1") : l.t("guide.newMac.1.fromBackup"),
                      l.t("reinstall.macreplica.open", backupFolderName ?? "MacReplica-Backup-…")], ordered: true)

        body += h2(10, "reinstall.restore.title")
        body += list([l.t("guide.newMac.3"), l.t("guide.newMac.4"), l.t("guide.newMac.5"), l.t("guide.newMac.6")], ordered: true)

        body += h2(11, "reinstall.verify.title")
        body += list([l.t("guide.newMac.7"), l.t("guide.newMac.8"), l.t("reinstall.verify.apps"), l.t("reinstall.verify.keepBackup")])

        body += h2(12, "reinstall.help.title")
        var links = [link(AppleSupportLinks.reinstall, "reinstall.link.reinstall"), link(AppleSupportLinks.recovery, "reinstall.link.recovery")]
        switch profile.family {
        case .appleSilicon: links.append(link(AppleSupportLinks.eraseAppleSilicon, "reinstall.link.erase"))
        case .intel, .intelT2:
            links.append(link(AppleSupportLinks.startupKeys, "reinstall.link.startupKeys"))
            links.append(link(AppleSupportLinks.eraseIntel, "reinstall.link.erase"))
        }
        if profile.hasEraseAllContentAndSettings { links.append(link(AppleSupportLinks.eraseAllContent, "reinstall.link.eraseAll")) }
        links.append(link(AppleSupportLinks.bootableInstaller, "reinstall.link.bootable"))
        if profile.family == .intelT2 { links.append(link(AppleSupportLinks.startupSecurityUtility, "reinstall.link.securityUtility")) }
        body += "<ul>" + links.joined() + "</ul>"
        body += p(l.t("reinstall.help.trouble"))

        let subtitle = l.t("reinstall.subtitle", l.t("reinstall.family.\(profile.family.rawValue)"), profile.macOSVersion)
        return page(title: l.t("reinstall.title"), subtitle: subtitle, body: body)
    }
}
