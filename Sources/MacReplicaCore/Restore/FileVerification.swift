import ColorSync
import Foundation

/// Checks that macOS on this Mac can use a restored font or profile, beyond the checksum.
enum FileVerification {
    static func isUsable(_ url: URL, kind: BackupFileKind) -> Bool {
        switch kind {
        case .font:
            // Legacy formats are never opened; for them the checksum is the only check.
            if FileScanner.isLegacyFontFormat(url) { return true }
            return FileScanner.fontIdentity(url) != nil
        case .colorProfile:
            return FileScanner.profileIdentity(url) != nil && colorSyncAccepts(url)
        }
    }

    /// `ColorSyncProfileVerify` returns true "if the profile can be used"; warnings do not prevent use.
    static func colorSyncAccepts(_ url: URL) -> Bool {
        guard let profile = ColorSyncProfileCreateWithURL(url as CFURL, nil)?.takeRetainedValue() else { return false }
        return ColorSyncProfileVerify(profile, nil, nil)
    }
}
