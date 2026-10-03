import Foundation
import Security

/// Read-only information about application bundles that does not need external tools.
public enum BundleInspection {
    /// The organization name from the bundle's Developer ID certificate,
    /// e.g. `Example Software Ltd` for "Developer ID Application: Example Software Ltd (ABCDE12345)".
    public static func signingVendor(of bundle: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String?
        else {
            return nil
        }
        return vendor(fromCertificateSummary: summary)
    }

    /// Extracts the organization from a Developer ID certificate subject. Apple's own
    /// signing identities (App Store, system) do not name the vendor and return nil.
    public static func vendor(fromCertificateSummary summary: String) -> String? {
        let prefixes = ["Developer ID Application: ", "Apple Development: ", "Apple Distribution: "]
        guard let prefix = prefixes.first(where: { summary.hasPrefix($0) }) else { return nil }
        var name = String(summary.dropFirst(prefix.count))
        if let range = name.range(of: #" \([A-Z0-9]{10}\)$"#, options: .regularExpression) {
            name.removeSubrange(range)
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Cleans an `NSHumanReadableCopyright` string down to the holder's name,
    /// e.g. "Copyright © 2019–2024 Example Inc. All rights reserved." → "Example Inc."
    public static func vendor(fromCopyright copyright: String) -> String? {
        var text = copyright.replacingOccurrences(of: "\n", with: " ")
        let removals = [
            #"(?i)all rights reserved\.?"#,
            #"(?i)copyright"#,
            #"©"#,
            #"\(c\)"#,
            #"(?i)\(C\)"#,
            #"\b(19|20)\d{2}\s*([-–—]\s*(19|20)?\d{2,4})?\b,?"#,
        ]
        for pattern in removals {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.;-–—").union(.whitespaces))
        guard !text.isEmpty, text.count <= 80 else { return nil }
        // Restore the trailing period of common company suffixes that the trim removed.
        for suffix in ["Inc", "Ltd", "Co", "Corp", "S.A", "B.V", "e.V"] where text.hasSuffix(suffix) {
            return text + "."
        }
        return text
    }

    /// The browser or app that downloaded the bundle, from the quarantine attribute.
    /// Returns nil when the attribute is missing — for example for App Store apps.
    public static func quarantineAgent(of url: URL) -> String? {
        let name = "com.apple.quarantine"
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = getxattr(url.path, name, &buffer, length, 0, 0)
        guard read > 0 else { return nil }
        return quarantineAgent(fromAttribute: String(decoding: buffer.prefix(read), as: UTF8.self))
    }

    /// The attribute looks like `0083;65a1b2c3;Safari;UUID`; the third field is the agent.
    public static func quarantineAgent(fromAttribute value: String) -> String? {
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }
        let agent = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
        return agent.isEmpty ? nil : agent
    }

    /// The Team ID and signing identifier of a signed bundle (read locally, no network).
    /// Ad-hoc and Apple platform signatures have no Team ID.
    public static func signingIdentity(of bundle: URL) -> (teamIdentifier: String?, identifier: String?)? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
        guard team != nil || identifier != nil else { return nil }
        return (team.flatMap { $0.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil ? $0 : nil }, identifier)
    }

    /// True if the bundle's code signature is intact (all architectures, nested code, strict) and, when
    /// `teamIdentifier` is given, issued by Apple to that developer team (Developer ID or App Store).
    public static func hasValidSignature(_ bundle: URL, teamIdentifier: String?) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var requirement: SecRequirement?
        if let team = teamIdentifier {
            guard team.range(of: #"^[A-Z0-9]{10}$"#, options: .regularExpression) != nil,
                  SecRequirementCreateWithString("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString, [], &requirement)
                    == errSecSuccess else { return false }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
    }

    public static func hasAppStoreReceipt(_ bundle: URL) -> Bool {
        FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/_MASReceipt/receipt").path)
    }
}
