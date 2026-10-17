// Reproduction probe (not part of MacReplica): how a process started by LaunchServices sees the Launchpad database.
import Foundation
var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
let n = confstr(_CS_DARWIN_USER_DIR, &buffer, buffer.count)
let dir = n > 0 ? String(cString: buffer) : "<confstr failed>"
let db = (dir as NSString).appendingPathComponent("com.apple.dock.launchpad/db/db")
var lines = ["confstr=\(n) dir=\(dir)", "db exists=\(FileManager.default.fileExists(atPath: db))",
             "TMPDIR=\(ProcessInfo.processInfo.environment["TMPDIR"] ?? "-")", "uid=\(getuid()) euid=\(geteuid())"]
let folder = (dir as NSString).appendingPathComponent("com.apple.dock.launchpad/db")
lines.append("db folder: " + ((try? FileManager.default.contentsOfDirectory(atPath: folder))?.sorted().joined(separator: ",") ?? "<unreadable>"))
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/launchpad-probe.txt"
try! (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
