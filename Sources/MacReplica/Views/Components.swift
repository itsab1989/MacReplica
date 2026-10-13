import AppKit
import MacReplicaCore
import SwiftUI

/// The standard layout of a screen: title, optional subtitle, content and a bottom button bar.
struct ScreenLayout<Content: View, Buttons: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 14)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()
            HStack(spacing: 10) { buttons }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

/// A rounded container used for summaries.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// An icon, a label and a number on one line.
struct CountRow: View {
    var symbol: String
    var color: Color
    var label: String
    var value: Int
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text("\(value)")
                .font(.body.monospacedDigit().weight(.medium))
        }
    }
}

/// A short highlighted message: information, warning or error.
struct NoticeView: View {
    enum Style { case info, warning, error, success }

    var style: Style
    var title: String
    var message: String?

    private var symbol: String {
        switch style {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch style {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.1)))
    }
}

/// Status symbol for a finished step.
struct OutcomeIcon: View {
    var outcome: ItemOutcome

    var body: some View {
        switch outcome {
        case .succeeded, .alreadyPresent:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped:
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

enum Symbols {
    static func category(_ category: RestoreCategory) -> String {
        switch category {
        case .homebrew: return "mug"
        case .appStore: return "bag"
        case .officialDownload: return "arrow.down.circle"
        case .manual: return "hand.point.up.left"
        }
    }

    static func component(_ component: RestoreComponent) -> String {
        switch component {
        case .applications: return "square.grid.2x2"
        case .brewFormulae: return "terminal"
        case .brewCasks: return "shippingbox"
        case .appStore: return "bag"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .developerTools: return "hammer"
        case .packageManagers: return "shippingbox.and.arrow.backward"
        case .developerSettings: return "wrench.and.screwdriver"
        case .credentials: return "key"
        case .applicationData: return "folder"
        case .fonts: return "textformat"
        case .colorProfiles: return "paintpalette"
        case .launchpad: return "square.grid.3x3"
        case .personalFolders: return "folder"
        }
    }

    static func kind(_ kind: RestoreItemKind) -> String {
        switch kind {
        case .commandLineTools: return "hammer"
        case .homebrew: return "mug"
        case .tap: return "point.3.connected.trianglepath.dotted"
        case .masTool, .appStoreApp: return "bag"
        case .formula: return "terminal"
        case .cask: return "shippingbox"
        case .font: return "textformat"
        case .colorProfile: return "paintpalette"
        case .pythonEnvironment: return "chevron.left.forwardslash.chevron.right"
        case .applicationData: return "folder"
        case .gitConfiguration: return "wrench.and.screwdriver"
        case .credential: return "key"
        case .toolchainStep: return "hammer"
        case .manualApp: return "arrow.down.circle"
        case .displayProfile: return "display"
        case .launchpadLayout: return "square.grid.3x3"
        }
    }

    static func ecosystem(_ ecosystem: Ecosystem) -> String {
        switch ecosystem {
        case .packageManagers: return "shippingbox.and.arrow.backward"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .node: return "hexagon"
        case .ruby: return "diamond"
        case .rust: return "gearshape.2"
        case .go: return "hare"
        case .java: return "cup.and.saucer"
        case .dotnet: return "circle.hexagongrid"
        }
    }
}

/// The application icon as shown in the Dock.
struct AppIconView: View {
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// SwiftUI's `State` property wrapper under a different name.
///
/// Recent SDKs also declare a `State` macro whose implementation ships only with
/// full Xcode. Using the property wrapper through this alias keeps the app
/// buildable with the Command Line Tools alone and behaves exactly like `@State`.
typealias ViewState = SwiftUI.State

/// Visible help for a control: a “?” button that shows the explanation in a popover when clicked.
///
/// Hover tooltips alone were easy to miss (they need the pointer to rest on the control while the window is active,
/// and nothing shows that they exist). The same text is also the tooltip and the accessibility hint, so it is
/// reachable with the mouse, the keyboard and VoiceOver.
struct HelpButton: View {
    @EnvironmentObject var model: AppModel
    var text: String
    var title: String? = nil
    /// Accessibility identifier, e.g. `help.ownInstaller.include`.
    var id: String? = nil
    @ViewState private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "questionmark.circle")
                .imageScale(.medium)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(text)
        .accessibilityLabel(title.map { model.l.t("help.button.named", $0) } ?? model.l.t("help.button"))
        .accessibilityHint(text)
        .accessibilityIdentifier(id ?? "help")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if let title { Text(title).font(.headline) }
                Text(text).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier((id ?? "help") + ".text")
            }
            .padding(14)
            .frame(width: 340, alignment: .leading)
        }
    }
}

/// A label followed by its help button, for section headings and options.
struct LabelWithHelp: View {
    var label: String
    var help: String
    var id: String? = nil
    var font: Font = .body

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(label).font(font)
            HelpButton(text: help, title: label, id: id)
        }
    }
}
