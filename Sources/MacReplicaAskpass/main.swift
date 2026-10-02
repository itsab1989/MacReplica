// MacReplicaAskpass — the password prompt Homebrew uses through SUDO_ASKPASS.
//
// Some Homebrew casks run an installer package that needs administrator rights.
// Homebrew then calls `sudo -A`, which starts this helper. It shows a native
// password dialog, writes the password to standard output for sudo, and exits.
// The password is never stored, logged or sent anywhere else.
//
// Texts are passed in by MacReplica in the user's chosen language via
// MACREPLICA_ASKPASS_TITLE / _MESSAGE / _OK / _CANCEL.

import AppKit

let environment = ProcessInfo.processInfo.environment
let title = environment["MACREPLICA_ASKPASS_TITLE"] ?? "Administrator password needed"
let message = environment["MACREPLICA_ASKPASS_MESSAGE"]
    ?? "Homebrew needs your administrator password to finish installing an app that MacReplica is restoring."
let okTitle = environment["MACREPLICA_ASKPASS_OK"] ?? "OK"
let cancelTitle = environment["MACREPLICA_ASKPASS_CANCEL"] ?? "Cancel"

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.activate(ignoringOtherApps: true)

let alert = NSAlert()
alert.messageText = title
alert.informativeText = message
alert.alertStyle = .informational
alert.addButton(withTitle: okTitle)
alert.addButton(withTitle: cancelTitle)
let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
alert.accessoryView = field
alert.window.initialFirstResponder = field

let response = alert.runModal()
guard response == .alertFirstButtonReturn else { exit(1) }
FileHandle.standardOutput.write(Data((field.stringValue + "\n").utf8))
exit(0)
