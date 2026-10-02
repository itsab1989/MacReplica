// Prints the window number of the frontmost on-screen window of an app, for
// `screencapture -l`. Development tool used for on-screen validation.
// Usage: window-id <owner name>
import CoreGraphics
import Foundation

let owner = CommandLine.arguments.dropFirst().first ?? "MacReplica"
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let match = windows.first { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0 }
if let number = match?[kCGWindowNumber as String] as? Int { print(number) } else { exit(1) }
