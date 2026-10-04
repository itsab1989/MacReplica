// MacReplicaAskpass — the password prompt Homebrew uses through SUDO_ASKPASS.
//
// Some Homebrew casks run an installer package that needs administrator rights.
// Homebrew then calls `sudo -A`, which starts this helper. It shows a native
// password dialog, writes the password to standard output for sudo, and exits.
// The password is never stored, logged or sent anywhere else.
//
// Texts are passed in by MacReplica in the user's chosen language via
// MACREPLICA_ASKPASS_TITLE / _MESSAGE / _OK / _CANCEL.

// During a restore MacReplica itself asks once and passes the checked password through a private
// local socket (MACREPLICA_ASKPASS_SOCKET, authenticated with MACREPLICA_ASKPASS_TOKEN), so each `sudo`
// call does not show a new dialog. The dialog below is only the fallback.

import AppKit
import Darwin

let environment = ProcessInfo.processInfo.environment

/// Asks MacReplica for the password. nil: no answer (fall back to the dialog); "" : the user cancelled.
func passwordFromMacReplica() -> String? {
    guard let path = environment["MACREPLICA_ASKPASS_SOCKET"], let token = environment["MACREPLICA_ASKPASS_TOKEN"] else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else { return nil }
    let request = Array((token + "\n").utf8)
    guard request.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == request.count else { return nil }
    var answer = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while true {
        let count = read(fd, &buffer, buffer.count)
        if count <= 0 { break }
        answer.append(contentsOf: buffer[0..<count])
    }
    let text = String(decoding: answer, as: UTF8.self)
    if text.hasPrefix("OK\t") { return String(text.dropFirst(3)).trimmingCharacters(in: .newlines) }
    if text.hasPrefix("CANCEL") { return "" }
    return nil
}

if let password = passwordFromMacReplica() {
    guard !password.isEmpty else { exit(1) }
    FileHandle.standardOutput.write(Data((password + "\n").utf8))
    exit(0)
}
// Tests: never show a dialog.
if environment["MACREPLICA_ASKPASS_NO_DIALOG"] == "1" { exit(1) }
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
// Started from a background process, the dialog would otherwise not always get the keyboard focus:
// typing then went elsewhere and an empty password was sent, which sudo rejects and asks again.
alert.window.level = .floating
alert.layout()
DispatchQueue.main.async {
    NSApp.activate(ignoringOtherApps: true)
    alert.window.makeKeyAndOrderFront(nil)
    alert.window.makeFirstResponder(field)
}

let response = alert.runModal()
guard response == .alertFirstButtonReturn else { exit(1) }
FileHandle.standardOutput.write(Data((field.stringValue + "\n").utf8))
exit(0)
