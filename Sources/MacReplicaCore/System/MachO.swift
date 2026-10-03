import Foundation

/// Reads the CPU architectures contained in a Mach-O executable without
/// running any external tool.
public enum MachO {
    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let fatMagic64: UInt32 = 0xCAFE_BABF
    private static let magic32: UInt32 = 0xFEED_FACE
    private static let magic64: UInt32 = 0xFEED_FACF

    private static let cpuTypeX86_64: UInt32 = 0x0100_0007
    private static let cpuTypeARM64: UInt32 = 0x0100_000C

    public static func architectures(ofFile url: URL) -> [CPUArchitecture] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return [] }
        return architectures(fromHeader: data)
    }

    public static func architectures(fromHeader data: Data) -> [CPUArchitecture] {
        guard data.count >= 8 else { return [] }
        let bigEndianMagic = readUInt32(data, at: 0, bigEndian: true)
        let littleEndianMagic = readUInt32(data, at: 0, bigEndian: false)

        if bigEndianMagic == fatMagic || bigEndianMagic == fatMagic64 {
            let count = Int(readUInt32(data, at: 4, bigEndian: true))
            let entrySize = bigEndianMagic == fatMagic64 ? 32 : 20
            // A real fat header never has more than a handful of slices; reject garbage.
            guard count > 0, count <= 16 else { return [] }
            var result: [CPUArchitecture] = []
            for index in 0..<count {
                let offset = 8 + index * entrySize
                guard offset + 4 <= data.count else { break }
                let cpu = readUInt32(data, at: offset, bigEndian: true)
                let arch = architecture(forCPUType: cpu)
                if arch != .unknown, !result.contains(arch) { result.append(arch) }
            }
            return result
        }

        if littleEndianMagic == magic64 || littleEndianMagic == magic32 {
            let cpu = readUInt32(data, at: 4, bigEndian: false)
            let arch = architecture(forCPUType: cpu)
            return arch == .unknown ? [] : [arch]
        }
        return []
    }

    /// The minimum macOS version a Mach-O file needs (`LC_BUILD_VERSION` or `LC_VERSION_MIN_MACOSX`),
    /// e.g. "13.0". For universal files the highest value of all slices; nil if none is recorded.
    public static func minimumMacOS(ofFile url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= 32 else { return nil }
        let big = readUInt32(data, at: 0, bigEndian: true)
        var offsets: [Int] = []
        if big == fatMagic || big == fatMagic64 {
            let count = Int(readUInt32(data, at: 4, bigEndian: true))
            guard count > 0, count <= 16 else { return nil }
            for index in 0..<count {
                let entry = 8 + index * (big == fatMagic64 ? 32 : 20)
                offsets.append(big == fatMagic64 ? Int(readUInt64(data, at: entry + 8)) : Int(readUInt32(data, at: entry + 8, bigEndian: true)))
            }
        } else {
            offsets = [0]
        }
        let versions = offsets.compactMap { minimumVersion(data, at: $0) }
        return versions.max { VersionComparison.compare($0, $1) == .orderedAscending }
    }

    static func minimumVersion(_ data: Data, at base: Int) -> String? {
        let magic = readUInt32(data, at: base, bigEndian: false)
        guard magic == magic64 || magic == magic32 else { return nil }
        let commands = Int(readUInt32(data, at: base + 16, bigEndian: false))
        var offset = base + (magic == magic64 ? 32 : 28)
        for _ in 0..<min(commands, 512) {
            let command = readUInt32(data, at: offset, bigEndian: false)
            let size = Int(readUInt32(data, at: offset + 4, bigEndian: false))
            guard size >= 8 else { return nil }
            // LC_BUILD_VERSION: platform (1 = macOS) then minos; LC_VERSION_MIN_MACOSX: version.
            if command == 0x32, readUInt32(data, at: offset + 8, bigEndian: false) == 1 {
                return decode(readUInt32(data, at: offset + 12, bigEndian: false))
            }
            if command == 0x24 { return decode(readUInt32(data, at: offset + 8, bigEndian: false)) }
            offset += size
            if offset >= data.count { break }
        }
        return nil
    }

    /// `xxxx.yy.zz` packed into 32 bits.
    static func decode(_ value: UInt32) -> String {
        let patch = value & 0xFF
        let version = "\(value >> 16).\((value >> 8) & 0xFF)"
        return patch == 0 ? version : version + ".\(patch)"
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        UInt64(readUInt32(data, at: offset, bigEndian: true)) << 32 | UInt64(readUInt32(data, at: offset + 4, bigEndian: true))
    }

    static func architecture(forCPUType cpu: UInt32) -> CPUArchitecture {
        switch cpu {
        case cpuTypeARM64: return .arm64
        case cpuTypeX86_64: return .x86_64
        default: return .unknown
        }
    }

    private static func readUInt32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        var value: UInt32 = 0
        for i in 0..<4 {
            let byte = UInt32(data[data.startIndex + offset + i])
            value |= bigEndian ? byte << (8 * (3 - i)) : byte << (8 * i)
        }
        return value
    }
}
