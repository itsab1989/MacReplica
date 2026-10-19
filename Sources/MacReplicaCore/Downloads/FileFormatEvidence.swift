import Foundation

/// What a file's own bytes say about it, read without any tool.
///
/// `hdiutil` cannot tell MacReplica why it failed: its messages are translated into the user's language (also with
/// `LANG=en_US`) and its exit status is 1 for every failure – a damaged image, an image that is already open, a folder
/// that went away. So MacReplica only calls an installer damaged when the file itself proves it: a disk image whose
/// directory is missing or points past the end of the file, or one whose own checksum `hdiutil verify` rejects.
public enum FileFormatEvidence: Equatable, Sendable {
    /// A UDIF disk image (what `hdiutil create` makes): its 512-byte directory at the end is present and consistent.
    /// `hasChecksum`: the image carries a checksum that `hdiutil verify` can check.
    case udif(hasChecksum: Bool)
    /// A UDIF directory that points past the end of the file: the file was cut short.
    case udifTruncated
    /// A UDIF image whose list of contents (the XML property list the directory points to) cannot be read: the image
    /// is damaged. `hdiutil` then fails without a checksum report ("error 3840"), so only the bytes can prove it.
    case udifDirectoryDamaged
    /// Starts like a compressed disk image, but the directory at the end is missing: an interrupted download.
    case compressedImageWithoutDirectory
    /// A password-protected disk image. `hdiutil` waits for the password (in a dialog) instead of failing, so it is
    /// never run on such a file.
    case encrypted
    /// A disk image without a directory (read/write, CD/DVD master, sparse): it has no checksum of its own.
    case rawImage
    /// Not a disk image, but recognisably something else.
    case otherFormat(OtherFormat)
    /// Nothing recognisable.
    case unknown

    public enum OtherFormat: String, Equatable, Sendable {
        /// An empty file.
        case empty
        /// A web page, typically an error page a browser saved instead of the download.
        case webPage
        case zipArchive
        /// An installer package (flat, xar).
        case installerPackage
        case pdf
    }

    /// The file is certainly not a usable disk image, whatever `hdiutil` reports.
    public var provesNotADiskImage: Bool {
        switch self {
        case .udifTruncated, .compressedImageWithoutDirectory, .otherFormat: return true
        case .udif, .udifDirectoryDamaged, .encrypted, .rawImage, .unknown: return false
        }
    }

    /// Reads the start and the end of the file. Nil when the file cannot be read.
    public static func examine(_ file: URL) -> FileFormatEvidence? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        guard size > 0 else { return .otherFormat(.empty) }
        guard (try? handle.seek(toOffset: 0)) != nil, let head = try? handle.read(upToCount: 4096) else { return nil }
        var trailer = Data()
        if size >= 512 {
            guard (try? handle.seek(toOffset: size - 512)) != nil, let data = try? handle.read(upToCount: 512) else { return nil }
            trailer = data
        }
        var sector16 = Data()
        if size >= 32_774 {
            // ISO 9660: "CD001" at byte 1 of the volume descriptor in sector 16.
            if (try? handle.seek(toOffset: 32_769)) != nil { sector16 = (try? handle.read(upToCount: 5)) ?? Data() }
        }
        let evidence = classify(head: head, trailer: trailer, size: size, sector16: sector16)
        // The list of contents must be a readable property list (its position was checked by `classify`).
        if case .udif = evidence {
            let offset = readUInt64(trailer, 216), length = readUInt64(trailer, 224)
            if length > 0, length <= 256 * 1_048_576, (try? handle.seek(toOffset: offset)) != nil,
               let xml = try? handle.read(upToCount: Int(length)), !directoryIsReadable(xml) {
                return .udifDirectoryDamaged
            }
        }
        return evidence
    }

    /// True when the image's list of contents is a property list.
    static func directoryIsReadable(_ xml: Data) -> Bool {
        (try? PropertyListSerialization.propertyList(from: xml, format: nil)) != nil
    }

    /// The classification of `examine`, on bytes (tested without files).
    static func classify(head: Data, trailer: Data, size: UInt64, sector16: Data = Data()) -> FileFormatEvidence {
        let head = Data(head)
        let trailer = Data(trailer)
        func bytes(_ data: Data, _ offset: Int, _ text: String) -> Bool {
            let pattern = Array(text.utf8)
            guard data.count >= offset + pattern.count else { return false }
            return Array(data[offset..<(offset + pattern.count)]) == pattern
        }
        // Encrypted images: version 2 starts with "encrcdsa", version 1 ends with "cdsaencr".
        if bytes(head, 0, "encrcdsa") || (trailer.count == 512 && bytes(trailer, 504, "cdsaencr")) { return .encrypted }
        if trailer.count == 512, bytes(trailer, 0, "koly") {
            let dataEnd = readUInt64(trailer, 24).addingReportingOverflow(readUInt64(trailer, 32))
            let xmlEnd = readUInt64(trailer, 216).addingReportingOverflow(readUInt64(trailer, 224))
            let limit = size - 512
            guard !dataEnd.overflow, !xmlEnd.overflow, dataEnd.partialValue <= limit, xmlEnd.partialValue <= limit else { return .udifTruncated }
            // Data fork checksum type at 80, master checksum type at 352; 0 means none.
            return .udif(hasChecksum: readUInt32(trailer, 80) != 0 || readUInt32(trailer, 352) != 0)
        }
        if bytes(head, 0, "sprs") || bytes(head, 0, "sprsbndl") { return .rawImage }
        // A partition map or a file system where a raw image has one.
        if bytes(head, 512, "EFI PART") || (bytes(head, 0, "ER") && bytes(head, 512, "PM")) || bytes(head, 1024, "H+") || bytes(head, 1024, "HX")
            || bytes(head, 32, "NXSB") || bytes(sector16, 0, "CD001") {
            return .rawImage
        }
        if bytes(head, 0, "xar!") { return .otherFormat(.installerPackage) }
        if bytes(head, 0, "PK\u{03}\u{04}") || bytes(head, 0, "PK\u{05}\u{06}") { return .otherFormat(.zipArchive) }
        if bytes(head, 0, "%PDF") { return .otherFormat(.pdf) }
        let text = String(decoding: head.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("<!doctype html") || text.hasPrefix("<html") || (text.hasPrefix("<?xml") && text.contains("<html")) {
            return .otherFormat(.webPage)
        }
        // The first block of a compressed UDIF image: zlib (UDZO), bzip2 (UDBZ), LZFSE (ULFO) or LZMA (ULMO).
        if head.count >= 2, head[0] == 0x78, [0x01, 0x5E, 0x9C, 0xDA].contains(head[1]) { return .compressedImageWithoutDirectory }
        if bytes(head, 0, "BZh") || bytes(head, 0, "bvx2") || bytes(head, 0, "bvx-") || bytes(head, 0, "bvxn") || bytes(head, 0, "bvx1") {
            return .compressedImageWithoutDirectory
        }
        if head.count >= 3, head[0] == 0x5D, head[1] == 0x00, head[2] == 0x00 { return .compressedImageWithoutDirectory }
        // A raw image of a disk with a classic (MBR) partition table.
        if head.count >= 512, head[510] == 0x55, head[511] == 0xAA { return .rawImage }
        return .unknown
    }

    private static func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}

/// A zip archive ends with its central directory; without it (a download cut short) nothing can be unpacked.
public enum ZipEvidence {
    /// The end-of-central-directory record is within the last 64 KiB + 22 bytes, as the format requires.
    public static func hasCentralDirectory(_ file: URL) -> Bool? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let length = min(size, 65_557)
        guard (try? handle.seek(toOffset: size - length)) != nil, let tail = try? handle.read(upToCount: Int(length)) else { return nil }
        let marker: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        let bytes = Array(tail)
        guard bytes.count >= 22 else { return false }
        for index in stride(from: bytes.count - 22, through: 0, by: -1) where Array(bytes[index..<(index + 4)]) == marker { return true }
        return false
    }
}
