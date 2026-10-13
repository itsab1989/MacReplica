import Foundation
import MacReplicaCore

/// The beta tester's situation (MacReplica 1.0.4 feedback): Cakebrew from a cask Homebrew has since removed, the
/// DisplayCAL suite (eight apps in one folder, its cask disabled), ChromIQ installed from its DMG (its cask is in the
/// developer's own tap), and an app whose cask is in a tap that is set up on this Mac.
extension SimulationRoot {
    public func addBetaFeedbackApps() throws {
        let applications = url.appendingPathComponent("Applications")
        func app(_ name: String, _ id: String, _ version: String, in folder: URL, extra: [String: Any] = [:]) throws {
            _ = try SimulationBuilder.makeSyntheticApp(name: name, bundleID: id, version: version, extraInfo: extra, in: folder)
        }
        // Cakebrew 1.3, installed with `brew install --cask cakebrew` before Homebrew removed the cask (2025-12-17).
        try app("Cakebrew", "com.brunophilipe.Cakebrew", "1.3", in: applications)
        try SimulationBuilder.write("1.3", to: state.appendingPathComponent("brew/casks/cakebrew"), executable: false)
        try setFlag("brew/cask-state/cakebrew", true, content: "removed")
        // The fake brew reads a cask's app from its spec; a removed cask keeps its installed definition.
        try SimulationBuilder.write(#"{"version": "1.3", "app": "Cakebrew.app", "bundle_id": "com.brunophilipe.Cakebrew"}"#,
                                    to: state.appendingPathComponent("brew/available/casks/cakebrew.json"), executable: false)
        // DisplayCAL 3.9.19: the suite folder with the main app and companions (same bundle identifiers as the real one).
        let suite = applications.appendingPathComponent("DisplayCAL")
        try FileManager.default.createDirectory(at: suite, withIntermediateDirectories: true)
        try app("DisplayCAL", "net.displaycal.DisplayCAL", "3.9.19", in: suite)
        try app("3D LUT Maker", "net.displaycal.DisplayCAL-3DLUT-maker", "3.9.19", in: suite)
        try app("Curve Viewer", "net.displaycal.DisplayCAL-curve-viewer", "3.9.19", in: suite)
        // ChromIQ 4.3.4 from the DMG on GitHub.
        try app("ChromIQ", "com.chromiq.app", "4.3.4", in: applications)
        // An app from a tap that is set up on this Mac (example/tools), installed from the vendor's DMG.
        try app("Tap Tool", "com.example.taptool", "2.0", in: applications)
        let tapCask: [String: Any] = ["token": "tap-tool", "full_token": "example/tools/tap-tool", "tap": "example/tools", "name": ["Tap Tool"],
                                      "homepage": "https://taptool.example.com/", "version": "2.1", "url": "https://taptool.example.com/TapTool.dmg",
                                      "artifacts": [["app": ["Tap Tool.app"]], ["zap": [["trash": ["~/Library/Preferences/com.example.taptool.plist"]]]]]]
        let data = try JSONSerialization.data(withJSONObject: tapCask)
        let folder = state.appendingPathComponent("brew/tap-casks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent("example__tools__tap-tool.json"))
        try SimulationBuilder.write(#"{"version": "2.1", "app": "Tap Tool.app", "bundle_id": "com.example.taptool"}"#,
                                    to: state.appendingPathComponent("brew/available/casks/example/tools/tap-tool.json"), executable: false)
        try SimulationBuilder.write(#"{"version": "4.3.4", "app": "ChromIQ.app", "bundle_id": "com.chromiq.app"}"#,
                                    to: state.appendingPathComponent("brew/available/casks/itsab1989/chromiq/chromiq.json"), executable: false)
        // Homebrew's catalog: DisplayCAL's cask is disabled (it installs a package and names no app, like the real one).
        let catalog = url.appendingPathComponent("catalog/cask.json")
        var casks = (try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? [[String: Any]]) ?? []
        casks.append(["token": "displaycal", "name": ["DisplayCAL"], "homepage": "https://displaycal.net/", "version": "3.8.9.3",
                      "artifacts": [["pkg": ["DisplayCAL-3.8.9.3.pkg"]], ["zap": [["trash": ["~/Library/Preferences/DisplayCAL"]]]]],
                      "deprecated": false, "disabled": true, "disable_date": "2026-09-01", "disable_reason": "fails_gatekeeper_check"])
        try JSONSerialization.data(withJSONObject: casks, options: [.prettyPrinted, .sortedKeys]).write(to: catalog)
        try addPrinters()
    }

    /// An older laser printer with the manufacturer's driver, an AirPrint printer, and a scanner driver.
    public func addPrinters() throws {
        let ppd = url.appendingPathComponent("etc/cups/ppd")
        try FileManager.default.createDirectory(at: ppd, withIntermediateDirectories: true)
        try SimulationBuilder.write("""
        *PPD-Adobe: "4.3"
        *Manufacturer: "Brother"
        *NickName: "Brother HL-5250DN BR-Script3"
        *cupsFilter: "application/vnd.cups-postscript 0 /Library/Printers/Brother/Filter/brother_lpdwrapper"
        *APPrinterIconPath: "/Library/Printers/Brother/Icons/HL5250.icns"
        """, to: ppd.appendingPathComponent("Office_Laser.ppd"), executable: false)
        try SimulationBuilder.write("""
        *PPD-Adobe: "4.3"
        *Manufacturer: "HP"
        *NickName: "HP Color LaserJet MFP M283fdw-AirPrint"
        *APAirPrint: True
        *cupsFilter2: "image/urf image/urf 0 -"
        """, to: ppd.appendingPathComponent("HP_Color_LaserJet_MFP.ppd"), executable: false)
        try SimulationBuilder.write("lpd://192.168.1.20/queue", to: state.appendingPathComponent("printers/Office_Laser"), executable: false)
        try SimulationBuilder.write("dnssd://HP%20Color%20LaserJet%20MFP%20M283fdw._ipps._tcp.local./?uuid=00000000-0000-1000-8000-0000000000aa",
                                    to: state.appendingPathComponent("printers/HP_Color_LaserJet_MFP"), executable: false)
        let devices = url.appendingPathComponent("Library/Image Capture/Devices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        _ = try SimulationBuilder.makeSyntheticApp(name: "EPSON Scanner", bundleID: "com.epson.scanner.ICA", version: "5.9.0", in: devices)
    }
}
