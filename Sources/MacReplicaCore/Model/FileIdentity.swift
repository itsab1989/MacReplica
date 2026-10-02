import Foundation

/// Where a font or profile came from on the old Mac, as far as it can be told from the file itself.
public enum FileOrigin: String, Codable, Sendable, CaseIterable {
    /// Installed by the user for their own account (`~/Library/…`).
    case userInstalled
    /// Installed for all users (`/Library/…`), usually by the user, an installer or an app.
    case sharedInstalled
    /// A profile created by Apple (creator `appl`) that sits in a library folder, typically left
    /// behind by an older macOS version or a printer/display setup.
    case appleCreated
    /// A profile macOS generated for a display connected to the old Mac (`/Library/ColorSync/Profiles/Displays`).
    case displayGenerated
}

/// Stable identity information of a font file, read with Core Text.
public struct FontIdentity: Codable, Equatable, Hashable, Sendable {
    /// PostScript names of all faces in the file; they identify a font independent of its file name.
    public var postScriptNames: [String]
    public var families: [String]
    public var styles: [String]
    /// The version string from the font's name table (name ID 5), e.g. "Version 2.001".
    public var version: String?
    /// "OpenType", "TrueType", "Collection", "PostScript Type 1", "Suitcase", "Web font" …
    public var format: String

    public init(postScriptNames: [String], families: [String], styles: [String], version: String?, format: String) {
        self.postScriptNames = postScriptNames
        self.families = families
        self.styles = styles
        self.version = version
        self.format = format
    }

    /// A short, user-facing name such as "Example Sans Bold".
    public var displayName: String {
        let family = families.first ?? postScriptNames.first ?? ""
        guard styles.count == 1, let style = styles.first, !["Regular", "Roman", "Book"].contains(style) else { return family }
        return "\(family) \(style)"
    }

    /// The version number without the "Version " prefix and trailing notes.
    public var shortVersion: String? {
        guard let version else { return nil }
        let trimmed = version.replacingOccurrences(of: "Version ", with: "", options: [.caseInsensitive, .anchored])
        return trimmed.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }
}

/// Identity information from an ICC profile header and description tag (ICC.1:2022, 7.2).
public struct ProfileIdentity: Codable, Equatable, Hashable, Sendable {
    public var description: String?
    /// Profile class: `mntr` (display), `prtr` (output), `scnr` (input), `spac`, `link`, `abst`, `nmcl`.
    public var deviceClass: String
    public var colorSpace: String
    public var connectionSpace: String
    public var version: String
    /// Profile creator signature (`appl` for Apple).
    public var creator: String?
    public var manufacturer: String?
    public var model: String?
    /// Creation date from the header, ISO 8601, if set.
    public var created: String?
    /// The MD5 Profile ID (bytes 84–99) in hex; nil when the profile leaves it zero (common in v2 profiles).
    public var profileID: String?
    /// The Profile ID computed from the content (ICC.1:2022 §7.2.18); equal values mean equivalent profiles.
    public var computedID: String?

    // Explicit keys so that the IDs survive the manifest's snake_case conversion ("profile_id" ↔ "profileId").
    private enum CodingKeys: String, CodingKey {
        case description, deviceClass, colorSpace, connectionSpace, version, creator, manufacturer, model, created
        case profileID = "profileId"
        case computedID = "computedId"
    }

    public init(description: String?, deviceClass: String, colorSpace: String, connectionSpace: String, version: String,
                creator: String? = nil, manufacturer: String? = nil, model: String? = nil, created: String? = nil, profileID: String? = nil,
                computedID: String? = nil) {
        self.computedID = computedID
        self.description = description
        self.deviceClass = deviceClass
        self.colorSpace = colorSpace
        self.connectionSpace = connectionSpace
        self.version = version
        self.creator = creator
        self.manufacturer = manufacturer
        self.model = model
        self.created = created
        self.profileID = profileID
    }

    public init(header: ICCProfileHeader) {
        self.init(description: header.description, deviceClass: header.deviceClass, colorSpace: header.colorSpace,
                  connectionSpace: header.connectionSpace, version: header.version, creator: header.creator,
                  manufacturer: header.manufacturer, model: header.model, created: header.created, profileID: header.profileID,
                  computedID: header.computedProfileID.isEmpty ? nil : header.computedProfileID)
    }

    public var isAppleCreated: Bool { creator == "appl" }
    public var isDisplayProfile: Bool { deviceClass == "mntr" }

    /// Two profiles describe the same thing when class, color space and description match.
    /// This is used to recognize profiles macOS already provides, never to declare files identical.
    public func describesSameProfile(as other: ProfileIdentity) -> Bool {
        guard let description, let otherDescription = other.description else { return false }
        return description.caseInsensitiveCompare(otherDescription) == .orderedSame
            && deviceClass == other.deviceClass && colorSpace == other.colorSpace
    }
}
