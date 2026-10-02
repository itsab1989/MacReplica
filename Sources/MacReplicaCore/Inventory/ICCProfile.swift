import CryptoKit
import Foundation

/// A minimal, read-only parser for ICC profile headers (ICC.1:2022, section 7.2)
/// and the profile description tag.
public struct ICCProfileHeader: Equatable, Sendable {
    public var size: UInt32
    public var version: String
    public var deviceClass: String
    public var colorSpace: String
    public var connectionSpace: String
    public var description: String?
    public var creator: String?
    public var manufacturer: String?
    public var model: String?
    /// Creation date (bytes 24–35) as ISO 8601, nil when unset.
    public var created: String?
    /// Profile ID (bytes 84–99) in hex, nil when all zero.
    public var profileID: String?
    /// The Profile ID computed as ICC.1:2022 §7.2.18 defines it: MD5 of the whole profile with the
    /// flags (44–47), rendering intent (64–67) and Profile ID (84–99) fields set to zero. Most
    /// profiles, including Apple's, leave the stored field empty, so this is what identifies content.
    public var computedProfileID: String = ""

    public static func parse(_ data: Data) -> ICCProfileHeader? {
        guard data.count >= 132 else { return nil }
        // Bytes 36–39 hold the profile file signature "acsp".
        guard string(data, at: 36, length: 4) == "acsp" else { return nil }
        let size = uint32(data, at: 0)
        let major = data[data.startIndex + 8]
        let minor = data[data.startIndex + 9] >> 4
        let bugfix = data[data.startIndex + 9] & 0x0F
        return ICCProfileHeader(
            size: size,
            version: "\(major).\(minor).\(bugfix)",
            deviceClass: string(data, at: 12, length: 4).trimmingCharacters(in: .whitespaces),
            colorSpace: string(data, at: 16, length: 4).trimmingCharacters(in: .whitespaces),
            connectionSpace: string(data, at: 20, length: 4).trimmingCharacters(in: .whitespaces),
            description: profileDescription(data),
            creator: signature(data, at: 80),
            manufacturer: signature(data, at: 48),
            model: modelSignature(data),
            created: creationDate(data),
            profileID: profileID(data),
            computedProfileID: computedProfileID(data))
    }

    public static func computedProfileID(_ data: Data) -> String {
        var bytes = [UInt8](data)
        for range in [44..<48, 64..<68, 84..<100] where range.upperBound <= bytes.count {
            for index in range { bytes[index] = 0 }
        }
        return Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// A four-character signature, or nil when it is zero.
    static func signature(_ data: Data, at offset: Int) -> String? {
        guard uint32(data, at: offset) != 0 else { return nil }
        let value = string(data, at: offset, length: 4).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\0")))
        guard !value.isEmpty, value.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 }) else {
            return String(format: "%08x", uint32(data, at: offset))
        }
        return value
    }

    /// The device model is a signature too, but often a plain number; both are only used for comparison.
    static func modelSignature(_ data: Data) -> String? {
        let value = uint32(data, at: 52)
        guard value != 0 else { return nil }
        return signature(data, at: 52)
    }

    static func creationDate(_ data: Data) -> String? {
        let parts = (0..<6).map { Int(uint16(data, at: 24 + $0 * 2)) }
        guard parts[0] >= 1900, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", parts[0], parts[1], parts[2], parts[3], parts[4], parts[5])
    }

    static func profileID(_ data: Data) -> String? {
        guard data.count >= 100 else { return nil }
        let bytes = data[(data.startIndex + 84)..<(data.startIndex + 100)]
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func isProfile(_ data: Data) -> Bool { parse(data) != nil }

    /// Reads the `desc` tag, which is either `desc` (v2 text description) or `mluc` (v4 localized).
    static func profileDescription(_ data: Data) -> String? {
        let tagCount = Int(uint32(data, at: 128))
        guard tagCount > 0, tagCount < 1000 else { return nil }
        for index in 0..<tagCount {
            let entry = 132 + index * 12
            guard entry + 12 <= data.count else { return nil }
            guard string(data, at: entry, length: 4) == "desc" else { continue }
            let offset = Int(uint32(data, at: entry + 4))
            let length = Int(uint32(data, at: entry + 8))
            guard offset >= 0, length >= 12, offset + length <= data.count else { return nil }
            let type = string(data, at: offset, length: 4)
            if type == "desc" {
                let count = Int(uint32(data, at: offset + 8))
                guard count > 0, offset + 12 + count <= data.count else { return nil }
                let bytes = data[(data.startIndex + offset + 12)..<(data.startIndex + offset + 12 + count)]
                return clean(String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self))
            }
            if type == "mluc" {
                let records = Int(uint32(data, at: offset + 8))
                guard records > 0, offset + 16 + 12 <= data.count else { return nil }
                let recordLength = Int(uint32(data, at: offset + 16 + 4))
                let recordOffset = Int(uint32(data, at: offset + 16 + 8))
                let start = offset + recordOffset
                guard recordLength > 0, start + recordLength <= data.count else { return nil }
                let bytes = Data(data[(data.startIndex + start)..<(data.startIndex + start + recordLength)])
                return clean(String(data: bytes, encoding: .utf16BigEndian) ?? "")
            }
        }
        return nil
    }

    private static func clean(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16 | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) << 8 | UInt16(data[base + 1])
    }

    private static func string(_ data: Data, at offset: Int, length: Int) -> String {
        guard offset + length <= data.count else { return "" }
        let bytes = data[(data.startIndex + offset)..<(data.startIndex + offset + length)]
        return String(decoding: bytes, as: UTF8.self)
    }
}
