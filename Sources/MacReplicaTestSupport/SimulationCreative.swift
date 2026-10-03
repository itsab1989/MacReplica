import Foundation

/// Synthetic Adobe Photoshop (release and beta) and DaVinci Resolve data, laid out as the vendors store it.
extension SimulationRoot {
    static let resolveLUTs = "Library/Application Support/Blackmagic Design/DaVinci Resolve/LUT"
    static let resolvePreferences = "home/Library/Preferences/Blackmagic Design/DaVinci Resolve"
    static let resolveSupport = "home/Library/Application Support/Blackmagic Design/DaVinci Resolve"
    public static let resolvePackage = "com.blackmagic-design.Manifest"

    private func file(_ path: String, _ text: String) throws {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
    }

    /// The old Mac's user data of Photoshop 2025, the Photoshop beta and DaVinci Resolve, plus files that
    /// must never be copied (machine preferences, caches, licence, database list, system preferences).
    public func addCreativeAppData(resolveVersion: String = "21.1.0") throws {
        let support = "home/Library/Application Support/Adobe"
        let prefs = "home/Library/Preferences"
        // Photoshop 2025: a preference file and panel contents next to its machine state.
        try file("\(prefs)/Adobe Photoshop 2025 Settings/Brushes.psp", "release brushes panel")
        try file("\(prefs)/Adobe Photoshop 2025 Settings/Adobe Photoshop 2025 Prefs.psp", "release preferences")
        try file("\(prefs)/Adobe Photoshop 2025 Settings/MachinePrefs.psp", "gpu tiles")
        try file("\(support)/Adobe Photoshop 2025/Presets/Brushes/Release Brushes.abr", "release brushes")
        // Photoshop beta: its own folders, the same file names with different content.
        try file("\(support)/Adobe Photoshop (Beta)/Presets/Actions/Beta Actions.atn", "beta actions")
        try file("\(support)/Adobe Photoshop (Beta)/Presets/Tools/Beta Tools.tpl", "beta tool presets")
        try file("\(support)/Adobe Photoshop (Beta)/AutoRecover/Untitled.psb", "recovery data")
        try file("\(support)/Adobe Photoshop (Beta)/CT Font Cache/AdobeFnt_OSFonts.lst", "font cache")
        for name in ["Brushes.psp", "Actions Palette.psp", "Swatches.psp"] {
            try file("\(prefs)/Adobe Photoshop (Beta) Settings/\(name)", "beta \(name)")
        }
        try file("\(prefs)/Adobe Photoshop (Beta) Settings/Adobe Photoshop (Beta) Prefs.psp", "beta preferences")
        try file("\(prefs)/Adobe Photoshop (Beta) Settings/WorkSpaces (Modified)/Retouch.psw", "beta workspace")
        try file("\(prefs)/Adobe Photoshop (Beta) Settings/New Doc Sizes.json", #"{"presets":[]}"#)
        for name in ["MachinePrefs.psp", "PluginCache.psp", "FMCache.psp", "LaunchEndFlag.psp", "sniffer-out.txt"] {
            try file("\(prefs)/Adobe Photoshop (Beta) Settings/\(name)", "machine state")
        }
        try file("\(support)/Color/Settings/Print Studio.csf", "color settings")
        // DaVinci Resolve: installed, with LUTs that came with it and the user's own.
        try installResolve(version: resolveVersion)
        try file("\(Self.resolveLUTs)/Custom Looks/Teal Orange.cube", "LUT_3D_SIZE 2\n0 0 0\n1 1 1\n")
        try file("\(Self.resolveLUTs)/Custom Looks/Film/Print Emulation.cube", "LUT_3D_SIZE 2\n0 0 0\n1 1 1\n")
        let dbVersion = "<!--DbAppVer=\"\(resolveVersion).0017\" DbPrjVer=\"17\"-->"
        try file("\(Self.resolvePreferences)/keyboard.preset.xml", "<?xml version=\"1.0\"?>\n\(dbVersion)\n<SmKeyboardPresetList/>")
        try file("\(Self.resolvePreferences)/UI.preset", "UI_Persistence\nsynthetic")
        try file("\(Self.resolvePreferences)/config.user.presets.xml", "<?xml version=\"1.0\"?>\n\(dbVersion)\n<SM_UserPrefsPresetList/>")
        try file("\(Self.resolvePreferences)/config.user.xml", "<?xml version=\"1.0\"?>\n\(dbVersion)\n<SM_UserPrefs/>")
        try file("\(Self.resolvePreferences)/config.dat", "Local.IO.HardwareDecodeMask = 1\nSystem.Scripting.Mode = 1\n")
        try file("\(Self.resolvePreferences)/dblist.conf", "Local Database:/Users/example/Resolve Project Library:*:::DISK\n")
        try file("\(Self.resolvePreferences)/recentprojects.conf", "project")
        try file("\(Self.resolveSupport)/Fairlight/Presets/EQ/Voice.preset", "eq")
        try file("\(Self.resolveSupport)/Fusion/Templates/Edit/Titles/Lower Third.setting", "{ Tools = {} }")
        try file("\(Self.resolveSupport)/Fusion/DiskCache/frame.raw", "cache")
        try file("\(Self.resolveSupport)/logs/ResolveDebug.txt", "log")
    }

    /// Simulates installing DaVinci Resolve: the app (in its own folder, as the vendor installer does), its
    /// shared LUT folder with the LUTs it ships, and the installer receipt that lists them.
    public func installResolve(version: String) throws {
        let folder = url.appendingPathComponent("Applications/DaVinci Resolve")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("DaVinci Resolve.app").path) {
            try FileManager.default.removeItem(at: folder.appendingPathComponent("DaVinci Resolve.app"))
        }
        try SimulationBuilder.makeSyntheticApp(name: "DaVinci Resolve", bundleID: "com.blackmagic-design.DaVinciResolve", version: version, in: folder)
        let shipped = ["Blackmagic Design/Blackmagic Gen 5 Film to Rec709.cube", "ACES/LMT ACES v0.1.1.cube", "Invert Color.ilut"]
        for path in shipped { try file("\(Self.resolveLUTs)/\(path)", "shipped \(path)") }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: url.appendingPathComponent(Self.resolveLUTs).path)
        let receipt = (["Applications/DaVinci Resolve/DaVinci Resolve.app", Self.resolveLUTs, Self.resolveLUTs + "/ACES"]
                       + shipped.map { Self.resolveLUTs + "/" + $0 }).joined(separator: "\n")
        try file("state/receipts/\(Self.resolvePackage)", receipt + "\n")
    }

    /// Simulates the user opening a Photoshop version once, which creates its (empty) folders.
    public func launchPhotoshop(_ folderName: String) throws {
        for path in ["home/Library/Application Support/Adobe/\(folderName)/Presets/Brushes", "home/Library/Preferences/\(folderName) Settings"] {
            try FileManager.default.createDirectory(at: url.appendingPathComponent(path), withIntermediateDirectories: true)
        }
    }
}
