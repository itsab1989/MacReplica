import Foundation

/// A minimal stand-in for a Go program: a Mach-O header followed by the module information
/// block the Go linker embeds (wrapped in the same 16-byte markers), so `go version -m`-style
/// readers find it. It is not executable.
public enum SyntheticGoBinary {
    static let start: [UInt8] = [0x30, 0x77, 0xaf, 0x0c, 0x92, 0x74, 0x08, 0x02, 0x41, 0xe1, 0xc1, 0x07, 0xe6, 0xd6, 0x18, 0xe6]
    static let end: [UInt8] = [0xf9, 0x32, 0x43, 0x31, 0x86, 0x18, 0x20, 0x72, 0x00, 0x82, 0x42, 0x10, 0x41, 0x16, 0xd8, 0xf2]

    public static func data(path: String, module: String, version: String) -> Data {
        var data = SimulationBuilder.machOHeader([.arm64])
        data.append(Data(repeating: 0, count: 64))
        data.append(Data("\u{ff} Go buildinf:".utf8))
        data.append(Data(start))
        data.append(Data("path\t\(path)\nmod\t\(module)\t\(version)\th1:synthetic=\nbuild\tGOARCH=arm64\n".utf8))
        data.append(Data(end))
        return data
    }
}
