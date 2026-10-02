import Foundation

public enum SystemInfo {
    /// The Mac's hardware architecture. `hw.optional.arm64` is checked so that the
    /// answer stays correct even if MacReplica itself runs under Rosetta.
    public static var currentArchitecture: CPUArchitecture {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0, value == 1 {
            return .arm64
        }
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        return .unknown
        #endif
    }

    public static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The MacReplica version. There is exactly one source: `MacReplicaVersion.current`.
    public static var appVersion: String { MacReplicaVersion.current }

    /// The build number written into the app bundle by `scripts/build-app.sh`, or "dev" for development builds.
    public static var buildNumber: String {
        guard Bundle.main.bundleIdentifier == "io.github.itsab1989.MacReplica",
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String, !build.isEmpty else { return "dev" }
        return build
    }
}

/// The project's public links. Each exists exactly once; every screen uses these constants.
public enum MacReplicaLinks {
    public static let repository = URL(string: "https://github.com/itsab1989/MacReplica")!
    /// The developer's verified Ko-fi page (also used by the author's other project, ChromIQ).
    public static let kofi = URL(string: "https://ko-fi.com/itsab1989")!
}

public enum MacReplicaVersion {
    /// The single, authoritative version (semantic versioning: MAJOR.MINOR.PATCH).
    /// `scripts/build-app.sh` copies it into the app bundle, the release workflow
    /// checks that the Git tag matches it, and a test checks CHANGELOG.md.
    public static let current = "1.0.0"
    public static let minimumMacOS = "13.0"
}

/// Compares dotted version strings such as `13.4` and `13.10.1` numerically.
public enum VersionComparison {
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }
}
