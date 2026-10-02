import AppKit
import MacReplicaCore
import SwiftUI

@main
struct MacReplicaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("MacReplica", id: "main") {
            RootView()
                .environmentObject(model)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 760, height: 600)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(model.l.t("menu.about")) { appDelegate.showAbout(model: model) }
                Button(model.l.t("update.check")) { model.checkForUpdates(userInitiated: true) }
            }
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Button(model.l.t("menu.help")) { model.openWebPage(AboutView.repositoryURL + "#readme") }
                Divider()
                Button(model.l.t("help.openLogs")) { model.openLogs() }
                Button(model.l.t("help.exportDiagnostics")) { model.exportDiagnosticReport() }
                Divider()
                Button(model.l.t("help.support")) { model.openWebPage(AboutView.kofiURL) }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var aboutWindow: NSWindow?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func showAbout(model: AppModel) {
        if aboutWindow == nil {
            let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: AboutView().environmentObject(model))
            window.center()
            aboutWindow = window
        }
        aboutWindow?.title = model.l.t("menu.about")
        aboutWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
