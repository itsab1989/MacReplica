import Foundation

/// Synthetic user data of Krita, GIMP, Inkscape, Scribus, DisplayCAL, BenQ Palette Master, XP-Pen, Microsoft Office,
/// Apple Mail, Cryptomator and a few configuration folders, laid out as the vendors store it, plus files that must
/// never be copied.
extension SimulationRoot {
    private func put(_ path: String, _ text: String, executable: Bool = false) throws {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path) }
    }

    /// The simulated Mac's home folder as an absolute path (what apps write into their settings).
    public var homePath: String { url.appendingPathComponent("home").standardizedFileURL.path }

    public func addWorkflowAppData() throws {
        let support = "home/Library/Application Support"
        let prefs = "home/Library/Preferences"
        // Krita: the resource folder with its database, a bundle and a Python plug-in; settings with an absolute path.
        try put("\(support)/krita/resourcecache.sqlite", "SQLite format 3 (tags and active bundles)")
        try put("\(support)/krita/Brush Pack.bundle", "bundle")
        try put("\(support)/krita/paintoppresets/Ink Pen.kpp", "preset")
        try put("\(support)/krita/workspaces/Painting.kws", "workspace")
        try put("\(support)/krita/pykrita/tools/__init__.py", "print('tool')")
        try put("\(support)/krita/pykrita/tools.desktop", "[Desktop Entry]")
        try put("\(support)/krita/krita.log", "log")
        try put("\(prefs)/kritarc", "[General]\nResourceDirectory=\(homePath)/Library/Application Support/krita\n")
        try put("\(prefs)/kritashortcutsrc", "[Shortcuts]\nbrush_tool=B\n")
        try put("\(prefs)/kritadisplayrc", "machine display settings")
        // GIMP 2.10: resources and settings; caches and history that GIMP rebuilds; an executable plug-in.
        try put("\(support)/GIMP/2.10/brushes/Grain.gbr", "brush")
        try put("\(support)/GIMP/2.10/palettes/Brand.gpl", "GIMP Palette")
        try put("\(support)/GIMP/2.10/gimprc", "(theme \"Dark\")")
        try put("\(support)/GIMP/2.10/tags.xml", "<resource identifier=\"external:\(homePath)/Library/Fonts/Brand.otf//Brand\"/>")
        try put("\(support)/GIMP/2.10/menurc", "(action \"file-new\" \"<Primary>n\")")
        try put("\(support)/GIMP/2.10/pluginrc", "plug-in cache")
        try put("\(support)/GIMP/2.10/documents", "recent files")
        try put("\(support)/GIMP/2.10/tmp/swap", "temporary")
        // GIMP 3.2 keeps thumbnails and font caches inside the profile.
        try put("\(support)/GIMP/2.10/cache/thumbnails/a.png", "thumbnail")
        try put("\(support)/GIMP/2.10/CrashLog/gimp-crash-1.txt", "crash")
        try put("\(support)/GIMP/2.10/plug-ins/sharpen/sharpen.py", "#!/usr/bin/env python\n", executable: true)
        try put("\(support)/GIMP/2.10/scripts/frame.scm", "(define (frame) 1)")
        // Inkscape.
        let inkscape = "\(support)/org.inkscape.Inkscape/config/inkscape"
        try put("\(inkscape)/preferences.xml", "<inkscape/>")
        try put("\(inkscape)/keys/default.xml", "<keys/>")
        try put("\(inkscape)/templates/Poster.svg", "<svg/>")
        try put("\(inkscape)/extensions/hatch.inx", "<inkscape-extension/>")
        try put("\(inkscape)/extension-errors.log", "log")
        // Scribus: preferences with absolute paths and shortcuts; palettes.
        try put("\(prefs)/Scribus/prefs150.xml", "<SCRIBUSPREFS><Paths Documents=\"\(homePath)/Documents/\"/><Shortcut Action=\"save\"/></SCRIBUSPREFS>")
        try put("\(support)/Scribus/palettes/House.xml", "<SCRIBUSCOLORS/>")
        try put("\(support)/Scribus/cache/img/thumb", "cache")
        // DisplayCAL: two calibrations, settings with absolute paths; downloads and logs stay behind.
        try put("\(support)/DisplayCAL/storage/Studio 2026-09-30/Studio 2026-09-30.icc", "ICC profile")
        try put("\(support)/DisplayCAL/storage/Studio 2026-09-30/Studio 2026-09-30.ti3", "measurements")
        try put("\(support)/DisplayCAL/storage/Studio 2026-09-30/Studio 2026-09-30.cal", "calibration curves")
        try put("\(support)/DisplayCAL/dl/i1d3/correction.ccss", "vendor download")
        try put("\(prefs)/DisplayCAL/DisplayCAL.ini",
                "[Default]\nprofile.save_path = \(homePath)/Library/Application Support/DisplayCAL/storage\nargyll.dir = /opt/homebrew/bin\n")
        try put("\(prefs)/DisplayCAL/DisplayCAL.lock", "lock")
        try put("\(support)/ArgyllCMS/i1d3 custom.ccmx", "self-made correction")
        // BenQ Palette Master Element: saved targets in /Users/Shared.
        try put("Users/Shared/RD/strings/benq_params", "target D65 120cd")
        // XP-Pen 4.0 driver.
        try put("home/.XPPen/config.xml", "<PenTableLists version=\"4.0.0\"><Pen PenBtn0=\"2\"/></PenTableLists>")
        try put("home/.XPPen/data/mymac.ini", "machine")
        // Microsoft Office: Normal template and AutoCorrect; Finder's folder-name translations and licensing data stay.
        let office = "home/Library/Group Containers/UBF8T346G9.Office"
        try put("\(office)/User Content.localized/Templates.localized/Normal.dotm", "Normal template")
        try put("\(office)/User Content.localized/Templates.localized/Letter.dotx", "user template")
        try put("\(office)/User Content.localized/Templates.localized/.localized/de.strings", "\"Templates\" = \"Vorlagen\";")
        try put("\(office)/User Content.localized/Startup.localized/Excel/Personal.xlsb", "macros")
        try put("\(office)/Microsoft Office ACL [English]", "teh=the")
        try put("\(office)/MicrosoftRegistrationDB.reg", "registration and identity")
        try put("\(office)/Library/Preferences/com.microsoft.office.licensingV2.plist", "licence")
        // Apple Mail: signatures and rules; mailboxes, the message index and accounts never.
        try put("home/Library/Mail/V10/MailData/Signatures/AllSignatures.plist", "<plist/>")
        try put("home/Library/Mail/V10/MailData/Signatures/1234.mailsignature", "Best regards")
        try put("home/Library/Mail/V10/MailData/SyncedRules.plist", "<plist>rule</plist>")
        try put("home/Library/Mail/V10/MailData/SyncedSmartMailboxes.plist", "<plist>smart</plist>")
        try put("home/Library/Mail/V10/MailData/Envelope Index", "message index")
        try put("home/Library/Mail/V10/0F2E-ACCOUNT/INBOX.mbox/Info.plist", "mailbox")
        // Cryptomator: one vault in the home folder (its vault file only; nothing is ever decrypted) and one on a drive.
        try put("home/Vaults/Private/vault.cryptomator", "vault configuration (signed JWT)")
        try put("home/Vaults/Private/d/AB/cipher.c9r", "encrypted")
        let settings: [String: Any] = ["writtenByVersion": "1.19.3", "directories": [
            ["id": "a1", "path": "\(homePath)/Vaults/Private", "displayName": "Private"],
            ["id": "b2", "path": "/Volumes/Backup Drive/Work", "displayName": "Work"]]]
        let json = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try put("\(support)/Cryptomator/settings.json", String(decoding: json, as: UTF8.self))
        try put("\(support)/Cryptomator/key.p12", "device key")
        try put("\(support)/Cryptomator/ipc.socket", "socket")
        // Configuration folders.
        try put("home/.config/karabiner/karabiner.json", "{\"profiles\":[]}")
        try put("home/.config/karabiner/automatic_backups/karabiner_20260101.json", "{}")
        try put("home/.hammerspoon/init.lua", "hs.alert.show('hi')")
    }
}
