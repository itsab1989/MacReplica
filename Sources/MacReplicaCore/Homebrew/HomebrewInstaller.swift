import Foundation

public enum HomebrewInstallError: Error, Equatable, Sendable {
    case releaseInfoUnavailable(String)
    case downloadFailed(String)
    case checksumMismatch
    case untrustedSignature(String)
    case installFailed(String)
    case notWorkingAfterInstall(String)
}

/// Provides a downloaded Homebrew installer package whose integrity and signature were checked.
public protocol HomebrewPackageSource: Sendable {
    func fetchVerifiedPackage(into folder: URL) async throws -> URL
}

/// Downloads the official `Homebrew.pkg` from Homebrew's GitHub releases.
///
/// The package is only installed if its SHA-256 matches the digest published by
/// GitHub for the release asset and it carries a valid Developer ID Installer
/// signature from Homebrew's Apple team. Nothing else is downloaded or run.
public struct GitHubHomebrewPackageSource: HomebrewPackageSource {
    public static let releaseURL = URL(string: "https://api.github.com/repos/Homebrew/brew/releases/latest")!
    /// Apple Developer Team ID of the Homebrew project.
    public static let teamIdentifier = "927JGANW46"
    static let downloadPrefix = "https://github.com/Homebrew/brew/releases/download/"

    public var runner: CommandRunning
    public var pkgutil: String

    public init(runner: CommandRunning, pkgutil: String = "/usr/sbin/pkgutil") {
        self.runner = runner
        self.pkgutil = pkgutil
    }

    public struct Asset: Equatable, Sendable {
        public var url: URL
        public var sha256: String?
    }

    /// Picks the installer package from GitHub's release JSON.
    public static func parseRelease(_ data: Data) throws -> Asset {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]] else {
            throw HomebrewInstallError.releaseInfoUnavailable("unexpected release JSON")
        }
        for asset in assets {
            guard let name = asset["name"] as? String,
                  name.range(of: #"^Homebrew(-[0-9][0-9.]*)?\.pkg$"#, options: .regularExpression) != nil,
                  let link = asset["browser_download_url"] as? String,
                  link.hasPrefix(downloadPrefix), let url = URL(string: link)
            else { continue }
            var sha: String?
            if let digest = asset["digest"] as? String, digest.hasPrefix("sha256:") {
                sha = String(digest.dropFirst("sha256:".count)).lowercased()
            }
            return Asset(url: url, sha256: sha)
        }
        throw HomebrewInstallError.releaseInfoUnavailable("no Homebrew.pkg asset")
    }

    /// Checks `pkgutil --check-signature` output for a trusted Homebrew signature.
    public static func isTrustedSignature(_ output: String) -> Bool {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.contains(where: { $0.hasPrefix("Status: signed by a developer certificate issued by Apple") }) else {
            return false
        }
        // The first certificate in the chain is the signing (leaf) certificate.
        guard let leaf = lines.first(where: { $0.hasPrefix("1. ") }),
              leaf.contains("Developer ID Installer:"), leaf.hasSuffix("(\(teamIdentifier))") else {
            return false
        }
        if let notarization = lines.first(where: { $0.hasPrefix("Notarization:") }) {
            return notarization.contains("trusted by the Apple notary service")
        }
        return true
    }

    public func fetchVerifiedPackage(into folder: URL) async throws -> URL {
        var request = URLRequest(url: Self.releaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        let asset: Asset
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw HomebrewInstallError.releaseInfoUnavailable("HTTP error")
            }
            asset = try Self.parseRelease(data)
        } catch let error as HomebrewInstallError {
            throw error
        } catch {
            throw HomebrewInstallError.downloadFailed(error.localizedDescription)
        }

        let destination = folder.appendingPathComponent("Homebrew.pkg")
        do {
            let (temporary, response) = try await URLSession.shared.download(from: asset.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: temporary)
                throw HomebrewInstallError.downloadFailed("HTTP error")
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch let error as HomebrewInstallError {
            throw error
        } catch {
            throw HomebrewInstallError.downloadFailed(error.localizedDescription)
        }

        if let expected = asset.sha256 {
            guard try Hashing.sha256Hex(ofFile: destination) == expected else { throw HomebrewInstallError.checksumMismatch }
        }
        let check = try await runner.run(Command(executable: pkgutil, arguments: ["--check-signature", destination.path], timeout: 120))
        guard check.succeeded, Self.isTrustedSignature(check.stdout) else {
            throw HomebrewInstallError.untrustedSignature(check.stdout)
        }
        return destination
    }
}

/// Installs Homebrew when it is missing and verifies that it works afterwards.
public struct HomebrewInstaller: Sendable {
    public var layout: SystemLayout
    public var runner: CommandRunning
    public var source: HomebrewPackageSource
    public var privileged: PrivilegedExecuting

    public init(layout: SystemLayout, runner: CommandRunning, source: HomebrewPackageSource, privileged: PrivilegedExecuting) {
        self.layout = layout
        self.runner = runner
        self.source = source
        self.privileged = privileged
    }

    public func install(reason: String, log: LogStore) async throws -> HomebrewInstallation {
        let workspace = try TemporaryWorkspace(cleaner: SafeCleaner(homeDirectory: layout.homeDirectory))
        defer { workspace.cleanup() }

        log.info("Downloading the Homebrew installer package", component: .homebrew)
        let package = try await source.fetchVerifiedPackage(into: workspace.url)
        log.info("Homebrew package verified, installing", component: .homebrew)
        do {
            try await privileged.run([.installPackage(package)], reason: reason)
        } catch PrivilegedError.denied {
            throw PrivilegedError.denied
        } catch {
            throw HomebrewInstallError.installFailed(String(describing: error))
        }

        // Verify instead of trusting the installer's exit code: brew must exist,
        // be executable, report a version and live at the expected prefix.
        switch await HomebrewClient(layout: layout, runner: runner).locate() {
        case .ready(let installation):
            log.info("Homebrew \(installation.version) is ready at \(layout.displayPath(installation.prefix))", component: .homebrew)
            return installation
        case .broken(_, let reason):
            throw HomebrewInstallError.notWorkingAfterInstall(reason)
        case .notInstalled:
            throw HomebrewInstallError.notWorkingAfterInstall("brew not found after installation")
        }
    }
}
