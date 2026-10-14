// Presses (or reads) the element of an app's windows whose AXIdentifier matches, through the accessibility API.
// Much faster than walking "entire contents" with System Events. Development tool for on-screen validation.
//   ax-press <app name> <identifier>          press the element
//   ax-press <app name> <identifier> --exists exit 0 if it exists
//   ax-press <app name> --ids <prefix>       print identifiers starting with prefix (and their titles/values)
//   ax-press <app name> <identifier> --help   print the element's hover text (AXHelp)
//   ax-press <app name> <identifier> --value  print the element's value (e.g. a text shown for copying)
//   ax-press <app name> <identifier> --set <text>  set a text field's value through accessibility (no keystrokes)
//   ax-press <app name> <identifier> --scroll scroll the element into view (AXScrollToVisible)
import AppKit
import ApplicationServices

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == args[0] }) else {
    FileHandle.standardError.write(Data("usage: ax-press <app> <identifier> [--exists] | <app> --ids <prefix>\n".utf8)); exit(2)
}
let root = AXUIElementCreateApplication(app.processIdentifier)

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func walk(_ element: AXUIElement, depth: Int = 0, _ visit: (AXUIElement) -> Bool) -> Bool {
    if visit(element) { return true }
    guard depth < 60, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else { return false }
    for child in children where walk(child, depth: depth + 1, visit) { return true }
    return false
}

if args[1] == "--ids" {
    let prefix = args.count > 2 ? args[2] : ""
    _ = walk(root) { element in
        if let id = attribute(element, "AXIdentifier") as? String, id.hasPrefix(prefix) {
            let title = (attribute(element, kAXTitleAttribute) as? String) ?? ""
            let value = attribute(element, kAXValueAttribute).map { "\($0)" } ?? ""
            print("\(id)\t\(title)\t\(value)")
        }
        return false
    }
    exit(0)
}

var found: AXUIElement?
_ = walk(root) { element in
    if (attribute(element, "AXIdentifier") as? String) == args[1] { found = element; return true }
    return false
}
guard let element = found else { exit(1) }
if args.contains("--exists") { exit(0) }
if args.contains("--value") {
    print(attribute(element, kAXValueAttribute).map { "\($0)" } ?? (attribute(element, kAXDescriptionAttribute) as? String) ?? "")
    exit(0)
}
if let index = args.firstIndex(of: "--set"), index + 1 < args.count {
    AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    exit(AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, args[index + 1] as CFString) == .success ? 0 : 4)
}
if args.contains("--scroll") {
    exit(AXUIElementPerformAction(element, "AXScrollToVisible" as CFString) == .success ? 0 : 5)
}
if args.contains("--help") {
    print((attribute(element, kAXHelpAttribute) as? String) ?? "")
    exit(0)
}
exit(AXUIElementPerformAction(element, kAXPressAction as CFString) == .success ? 0 : 3)
