import Foundation

/// Builds minimal but valid TrueType fonts for tests and the simulation, so that font
/// identity (family, style, PostScript name, version) can be tested with real Core Text
/// parsing and without shipping any real typeface. The fonts contain a single empty glyph.
public enum SyntheticFont {
    public static func make(family: String, style: String = "Regular", postScriptName: String? = nil,
                            version: String = "1.000", weight: UInt16 = 400) -> Data {
        let psName = postScriptName ?? (family + "-" + style).replacingOccurrences(of: " ", with: "")
        let tables: [(String, [UInt8])] = [
            ("OS/2", os2(weight: weight, bold: weight >= 700)),
            ("cmap", cmap()),
            ("glyf", [0, 0, 0, 0]),
            ("head", head(version: version, bold: weight >= 700)),
            ("hhea", hhea()),
            ("hmtx", be16(500) + be16(0)),
            ("loca", be16(0) + be16(0)),
            ("maxp", maxp()),
            ("name", name([
                (1, family), (2, style), (3, "MacReplica Synthetic:\(psName):\(version)"),
                (4, style == "Regular" ? family : "\(family) \(style)"), (5, "Version \(version)"), (6, psName),
            ])),
            ("post", be32(0x0003_0000) + [UInt8](repeating: 0, count: 28)),
        ]
        return assemble(tables)
    }

    // MARK: Tables

    private static func head(version: String, bold: Bool) -> [UInt8] {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        let revision = UInt32((parts.first ?? 1) << 16) | UInt32(min(parts.count > 1 ? parts[1] : 0, 0xFFFF))
        var t = be32(0x0001_0000) + be32(revision) + be32(0) + be32(0x5F0F_3CF5)
        t += be16(0x000B) + be16(1000)
        t += [UInt8](repeating: 0, count: 16) // created, modified
        t += be16(0) + be16(0) + be16(500) + be16(800) // xMin, yMin, xMax, yMax
        t += be16(bold ? 1 : 0) + be16(8) + be16(2) + be16(0) + be16(0)
        return t
    }

    private static func hhea() -> [UInt8] {
        var t = be32(0x0001_0000) + be16(800) + be16(UInt16(bitPattern: -200)) + be16(0)
        t += be16(500) + be16(0) + be16(0) + be16(500) + be16(1) + be16(0) + be16(0)
        t += [UInt8](repeating: 0, count: 8) + be16(0) + be16(1)
        return t
    }

    private static func maxp() -> [UInt8] {
        be32(0x0001_0000) + be16(1) + be16(0) + be16(0) + be16(0) + be16(0) + be16(2) + [UInt8](repeating: 0, count: 18)
    }

    private static func cmap() -> [UInt8] {
        // Format 4 with only the mandatory 0xFFFF end segment.
        let sub = be16(4) + be16(24) + be16(0) + be16(2) + be16(2) + be16(0) + be16(0)
            + be16(0xFFFF) + be16(0) + be16(0xFFFF) + be16(1) + be16(0)
        return be16(0) + be16(1) + be16(3) + be16(1) + be32(12) + sub
    }

    private static func os2(weight: UInt16, bold: Bool) -> [UInt8] {
        var t = be16(4) + be16(500) + be16(weight) + be16(5) + be16(0)
        t += [UInt8](repeating: 0, count: 20) // subscript/superscript/strikeout metrics
        t += be16(0) + [UInt8](repeating: 0, count: 10) + [UInt8](repeating: 0, count: 16) // family class, panose, unicode ranges
        t += Array("MRSY".utf8)
        t += be16(bold ? 0x20 : 0x40) + be16(0x20) + be16(0xFFFF)
        t += be16(800) + be16(UInt16(bitPattern: -200)) + be16(0) + be16(800) + be16(200)
        t += be32(1) + be32(0) + be16(500) + be16(700) + be16(0) + be16(0x20) + be16(1)
        return t
    }

    private static func name(_ records: [(UInt16, String)]) -> [UInt8] {
        var strings: [UInt8] = []
        var entries: [UInt8] = []
        for (id, value) in records {
            let encoded = Array(value.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
            entries += be16(3) + be16(1) + be16(0x0409) + be16(id) + be16(UInt16(encoded.count)) + be16(UInt16(strings.count))
            strings += encoded
        }
        return be16(0) + be16(UInt16(records.count)) + be16(UInt16(6 + entries.count)) + entries + strings
    }

    // MARK: File layout

    private static func assemble(_ tables: [(String, [UInt8])]) -> Data {
        let sorted = tables.sorted { $0.0 < $1.0 }
        let count = UInt16(sorted.count)
        var power = 1, exponent = 0
        while power * 2 <= Int(count) { power *= 2; exponent += 1 }
        var header = be32(0x0001_0000) + be16(count) + be16(UInt16(power * 16)) + be16(UInt16(exponent)) + be16(count * 16 - UInt16(power * 16))
        var offset = header.count + sorted.count * 16
        var directory: [UInt8] = []
        var body: [UInt8] = []
        var headOffset = 0
        for (tag, data) in sorted {
            if tag == "head" { headOffset = offset }
            directory += Array(tag.utf8) + be32(checksum(data)) + be32(UInt32(offset)) + be32(UInt32(data.count))
            let padded = data + [UInt8](repeating: 0, count: (4 - data.count % 4) % 4)
            body += padded
            offset += padded.count
        }
        header += directory
        var font = header + body
        // head.checkSumAdjustment = 0xB1B0AFBA − checksum of the whole font.
        do {
            let adjustment = 0xB1B0_AFBA &- checksum(font)
            font.replaceSubrange((headOffset + 8)..<(headOffset + 12), with: be32(adjustment))
        }
        return Data(font)
    }

    private static func checksum(_ data: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        var index = 0
        while index < data.count {
            var word: UInt32 = 0
            for byte in 0..<4 { word = word << 8 | UInt32(index + byte < data.count ? data[index + byte] : 0) }
            sum = sum &+ word
            index += 4
        }
        return sum
    }

    private static func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
    private static func be32(_ value: UInt32) -> [UInt8] { [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
}
