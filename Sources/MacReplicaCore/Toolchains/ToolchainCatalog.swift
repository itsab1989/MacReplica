import Foundation

/// All package and version managers MacReplica knows. New providers are added here and nowhere else:
/// scanning, the backup and restore selection, the restore plan and the reports work from this list.
public enum ToolchainCatalog {
    public static let providers: [any ToolchainProvider] = [
        // Package managers
        MacPortsProvider(), NixProvider(), PixiProvider(), MiseProvider(), AsdfProvider(), PkgxProvider(), FinkProvider(),
        // Python
        PyenvProvider(), UVProvider(), PipxProvider(), CondaProvider(),
        // Node.js
        NVMProvider(), FNMProvider(), VoltaProvider(), NPMProvider(), PNPMProvider(), YarnProvider(),
        // Ruby
        RbenvProvider(), RVMProvider(), GemProvider(),
        // Rust
        RustupProvider(), CargoProvider(),
        // Go
        GoProvider(),
        // Java
        JDKProvider(), SDKMANProvider(),
        // .NET
        DotnetProvider(),
    ]

    public static func provider(_ id: ToolchainProviderID) -> any ToolchainProvider {
        providers.first { $0.id == id }!
    }

    public static func descriptor(_ id: ToolchainProviderID) -> ToolchainDescriptor { provider(id).descriptor }

    /// Reads every provider. Only files are read; no tool is started.
    public static func scan(_ context: ToolchainContext) -> [ToolchainRecord] {
        providers.compactMap { provider in
            guard let record = provider.scan(context), !record.isEmpty || provider.descriptor.ecosystem == .packageManagers else { return nil }
            return record
        }
    }

    /// How the recorded items of `record` come back: automatic and/or guided, or nothing (listed only).
    /// Runtimes restored as Homebrew packages count as automatic.
    public static func supportLevels(for record: ToolchainRecord) -> Set<SupportLevel> {
        let provider = provider(record.provider)
        var levels = Set(provider.restoreActions(for: record).map { provider.supportLevel(for: $0) })
        if record.runtimes.contains(where: { provider.homebrewPackage(for: $0) != nil }) { levels.insert(.automatic) }
        levels.remove(.inventoryOnly)
        return levels
    }

    /// The executables the providers may start for `actions` — exactly these are added to the command policy.
    public static func executables(for actions: [ToolchainAction], context: ToolchainContext) -> Set<String> {
        Set(actions.flatMap { provider($0.provider).executableCandidates(for: $0, context: context) }.filter { $0.hasPrefix("/") })
    }
}
