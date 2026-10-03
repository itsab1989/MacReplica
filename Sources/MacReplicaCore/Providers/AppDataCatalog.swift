import Foundation

/// The application data providers MacReplica ships.
///
/// Research date for all entries: 2026-10-02. Every provider lists the sources its
/// locations come from; docs/PROVIDERS.md has the quoted evidence, rejected
/// candidates and limitations. Status `fixtureTested` means: implemented and covered
/// end to end by automated tests with synthetic data that mirrors the documented
/// layout — the real application was not launched by the tests.
public enum AppDataCatalog {
    static let researched = "2026-10-02"

    public static let providers: [AppDataProvider] = [
        // MARK: Developer tools
        AppDataProvider(
            id: "vscode", appName: "Visual Studio Code", bundleIdentifiers: ["com.microsoft.VSCode"],
            base: "Library/Application Support/Code/User", versionFolderPattern: nil,
            categories: [AppDataCategory("settings", "", files: ["settings.json", "keybindings.json"]),
                         AppDataCategory("snippets", "snippets"),
                         AppDataCategory("profiles", "profiles")],
            mustBeClosed: true, status: .fixtureTested,
            evidence: [Evidence(title: "VS Code: User and workspace settings", url: "https://code.visualstudio.com/docs/configure/settings"),
                       Evidence(title: "VS Code: Profiles", url: "https://code.visualstudio.com/docs/configure/profiles"),
                       Evidence(title: "VS Code: Extension Marketplace", url: "https://code.visualstudio.com/docs/configure/extensions/extension-marketplace")],
            researchedOn: researched,
            limitations: ["Extensions are not copied (binaries); their IDs are listed for reinstalling.",
                          "The snippets path is documented only in community sources."]),
        AppDataProvider(
            id: "cursor", appName: "Cursor", bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
            base: "Library/Application Support/Cursor/User", versionFolderPattern: nil,
            categories: [AppDataCategory("settings", "", files: ["settings.json", "keybindings.json"]),
                         AppDataCategory("snippets", "snippets")],
            mustBeClosed: true, status: .fixtureTested,
            evidence: [Evidence(title: "Cursor: Migrate from VS Code", url: "https://cursor.com/docs/configuration/migrations/vscode")],
            researchedOn: researched,
            limitations: ["The folder layout mirrors VS Code; Cursor documents the import, not the paths."]),
        AppDataProvider(
            id: "sublime-text", appName: "Sublime Text", bundleIdentifiers: ["com.sublimetext.4", "com.sublimetext.3"],
            base: "Library/Application Support", versionFolderPattern: #"^Sublime Text( 3)?$"#,
            categories: [AppDataCategory("userPackage", "Packages/User", excluding: [
                "Package Control.last-run", "Package Control.ca-list", "Package Control.ca-bundle", "Package Control.system-ca-bundle",
                "Package Control.cache", "Package Control.ca-certs"])],
            mustBeClosed: true, status: .fixtureTested,
            evidence: [Evidence(title: "Sublime Text: Reverting to a freshly installed state", url: "https://www.sublimetext.com/docs/revert.html"),
                       Evidence(title: "Package Control: Syncing", url: "https://packagecontrol.io/docs/syncing")],
            researchedOn: researched,
            limitations: ["Package Control caches inside Packages/User are excluded; packages are reinstalled by Package Control."]),
        AppDataProvider(
            id: "jetbrains", appName: "JetBrains IDEs",
            bundleIdentifiers: ["com.jetbrains.intellij", "com.jetbrains.intellij.ce", "com.jetbrains.pycharm", "com.jetbrains.pycharm.ce",
                                "com.jetbrains.WebStorm", "com.jetbrains.PhpStorm", "com.jetbrains.goland", "com.jetbrains.rubymine",
                                "com.jetbrains.CLion", "com.jetbrains.datagrip", "com.jetbrains.rider", "com.jetbrains.rustrover"],
            base: "Library/Application Support/JetBrains",
            versionFolderPattern: #"^(IntelliJIdea|IdeaIC|PyCharm|PyCharmCE|WebStorm|PhpStorm|GoLand|RubyMine|CLion|DataGrip|Rider|RustRover)\d{4}\.\d+$"#,
            categories: [AppDataCategory("keymaps", "keymaps"), AppDataCategory("codeStyles", "codestyles"),
                         AppDataCategory("colorSchemes", "colors"), AppDataCategory("liveTemplates", "templates"),
                         AppDataCategory("fileTemplates", "fileTemplates"), AppDataCategory("inspectionProfiles", "inspection"),
                         AppDataCategory("externalTools", "tools")],
            mustBeClosed: true, status: .fixtureTested,
            evidence: [Evidence(title: "JetBrains: Directories used by the IDE",
                                url: "https://www.jetbrains.com/help/idea/directories-used-by-the-ide-to-store-settings-caches-plugins-and-logs.html"),
                       Evidence(title: "JetBrains: Share IDE settings", url: "https://www.jetbrains.com/help/idea/sharing-your-ide-settings.html")],
            researchedOn: researched,
            limitations: ["options/ (machine-specific paths, SDK tables) and plugins are not copied.",
                          "Data is restored into the original version folder; a newer IDE imports it from there.",
                          "Bundle identifiers are not confirmed by JetBrains documentation."]),
        AppDataProvider(
            id: "xcode", appName: "Xcode", bundleIdentifiers: ["com.apple.dt.Xcode"],
            base: "Library/Developer/Xcode", versionFolderPattern: nil,
            categories: [AppDataCategory("codeSnippets", "UserData/CodeSnippets"), AppDataCategory("themes", "UserData/FontAndColorThemes"),
                         AppDataCategory("keyBindings", "UserData/KeyBindings"), AppDataCategory("templates", "Templates")],
            mustBeClosed: true, status: .fixtureTested,
            evidence: [Evidence(title: "Apple Developer Forums: moving Xcode customizations (community answer)",
                                url: "https://developer.apple.com/forums/thread/705846")],
            researchedOn: researched,
            limitations: ["Apple does not document these folders; the source is a community answer on Apple's forums."]),
        AppDataProvider(
            id: "bbedit", appName: "BBEdit", bundleIdentifiers: ["com.barebones.bbedit"],
            base: "Library/Application Support/BBEdit", versionFolderPattern: nil,
            categories: [AppDataCategory("clippings", "Clippings"), AppDataCategory("textFilters", "Text Filters"),
                         AppDataCategory("scripts", "Scripts"), AppDataCategory("stationery", "Stationery"),
                         AppDataCategory("languageModules", "Language Modules"), AppDataCategory("colorSchemes", "Color Schemes")],
            mustBeClosed: true, status: .fixtureTested,
            evidence: [Evidence(title: "BBEdit Application Support \"Read Me.txt\" (Bare Bones, mirrored)",
                                url: "https://github.com/gingi/BBEdit-Support/blob/master/Read%20Me.txt")],
            researchedOn: researched,
            limitations: ["Auto-Save Recovery and licence data are not copied."]),
        AppDataProvider(
            id: "iterm2", appName: "iTerm2", bundleIdentifiers: ["com.googlecode.iterm2"],
            base: "Library/Application Support/iTerm2", versionFolderPattern: nil,
            categories: [AppDataCategory("dynamicProfiles", "DynamicProfiles")],
            mustBeClosed: false, status: .fixtureTested,
            evidence: [Evidence(title: "iTerm2: Dynamic Profiles", url: "https://iterm2.com/documentation-dynamic-profiles.html")],
            researchedOn: researched,
            limitations: ["Only Dynamic Profiles; iTerm2's own Export/Import All Settings covers everything else."]),

        // MARK: Creative applications
        photoshopPresets(id: "adobe-photoshop", appName: "Adobe Photoshop", folderPattern: #"^Adobe Photoshop (\d{4}|CC \d{4}|CS\d)$"#),
        photoshopSettings(id: "adobe-photoshop-settings", appName: "Adobe Photoshop", folderPattern: #"^Adobe Photoshop (\d{4}|CC \d{4}) Settings$"#),
        // The beta keeps its own folders ("Adobe Photoshop (Beta)"), separate from the release, although the
        // app has the same bundle ID. Its data only ever goes back into the beta's folders.
        photoshopPresets(id: "adobe-photoshop-beta", appName: "Adobe Photoshop (Beta)", folderPattern: #"^Adobe Photoshop \(Beta\)$"#),
        photoshopSettings(id: "adobe-photoshop-beta-settings", appName: "Adobe Photoshop (Beta)", folderPattern: #"^Adobe Photoshop \(Beta\) Settings$"#),
        AppDataProvider(
            id: "adobe-color-settings", appName: "Adobe color settings",
            bundleIdentifiers: ["com.adobe.Photoshop", "com.adobe.illustrator", "com.adobe.InDesign", "com.adobe.LightroomClassicCC7"],
            base: "Library/Application Support/Adobe/Color", versionFolderPattern: nil,
            categories: [AppDataCategory("colorSettingsFiles", "Settings"), AppDataCategory("proofSetups", "Proofing")],
            mustBeClosed: false, status: .fixtureTested,
            evidence: [Evidence(title: "Adobe: Photoshop preference file names and locations (Userdefined.csf in Color/Settings)",
                                url: "https://helpx.adobe.com/photoshop/kb/preference-file-names-locations-photoshop.html")],
            researchedOn: researchedPS,
            limitations: ["Shared by all Adobe apps; each app shows the files in Edit › Color Settings.",
                          "Adobe pages could only be read through search excerpts."]),
        AppDataProvider(
            id: "adobe-camera-raw", appName: "Lightroom Classic / Camera Raw", bundleIdentifiers: ["com.adobe.LightroomClassicCC7", "com.adobe.Photoshop"],
            base: "Library/Application Support/Adobe/CameraRaw", versionFolderPattern: nil,
            categories: [AppDataCategory("developPresets", "Settings"), AppDataCategory("cameraProfiles", "CameraProfiles"),
                         AppDataCategory("rawDefaults", "Defaults")],
            mustBeClosed: true, status: .fixtureTested,
            evidence: [Evidence(title: "Adobe: Lightroom Classic preference and other file locations",
                                url: "https://helpx.adobe.com/lightroom-classic/desktop/kb/preference-file-and-other-file-locations.html"),
                       Evidence(title: "Adobe: Camera Raw default settings (RawDefaults.xmp)", url: "https://helpx.adobe.com/camera-raw/kb/acr-raw-defaults.html")],
            researchedOn: researched,
            limitations: ["Catalogs (.lrcat) are databases and never copied.",
                          "Presets stored with a catalog are not in this folder.",
                          "Camera Raw is also used inside Photoshop, so the data is not restored while Photoshop is open either."]),
        AppDataProvider(
            id: "capture-one", appName: "Capture One", bundleIdentifiers: ["com.captureone.captureone16"],
            base: "Library/Application Support/Capture One", versionFolderPattern: nil,
            categories: [AppDataCategory("styles", "Styles"), AppDataCategory("presets", "Presets60"),
                         AppDataCategory("shortcuts", "KeyboardShortcuts"), AppDataCategory("workspaces", "Workspaces")],
            mustBeClosed: true, status: .fixtureTested,
            evidence: [Evidence(title: "Capture One: Moving styles and presets to a new computer",
                                url: "https://support.captureone.com/hc/en-us/articles/27728350991261"),
                       Evidence(title: "Capture One: Transferring workspaces and presets",
                                url: "https://support.captureone.com/hc/en-us/articles/360002418657")],
            researchedOn: researched,
            limitations: ["Catalogs and sessions are moved separately; activation is account-based."]),
        AppDataProvider(
            id: "davinci-resolve", appName: "DaVinci Resolve", bundleIdentifiers: resolveIDs,
            base: "Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion", versionFolderPattern: nil,
            categories: [AppDataCategory("fusionTemplates", "Templates"), AppDataCategory("fusionMacros", "Macros"),
                         AppDataCategory("fuses", "Fuses"), AppDataCategory("fusionSettings", "Settings"),
                         AppDataCategory("fusionLUTs", "LUTs"),
                         // Scripts can hold API keys or server addresses.
                         AppDataCategory("fusionScripts", "Scripts", .mayContainSecrets)],
            mustBeClosed: true, status: .fixtureTested,
            evidence: [Evidence(title: "DaVinci Resolve 20 Reference Manual (Fusion template and macro folders)",
                                url: "https://documents.blackmagicdesign.com/UserManuals/DaVinci_Resolve_20_Reference_Manual.pdf")] + resolveEvidence,
            researchedOn: researchedResolve,
            limitations: ["Resolve scans templates and scripts when it starts.",
                          "Fusion's DiskCache and profile preferences (machine paths) are never copied."]),
        AppDataProvider(
            id: "davinci-resolve-luts", appName: "DaVinci Resolve", bundleIdentifiers: resolveIDs,
            base: "Application Support/Blackmagic Design/DaVinci Resolve/LUT", versionFolderPattern: nil,
            categories: [AppDataCategory("luts", "")],
            mustBeClosed: false, status: .fixtureTested, evidence: resolveEvidence, researchedOn: researchedResolve,
            limitations: ["The LUT folder is shared by all users (/Library); Resolve's installer creates it, so the LUTs wait until Resolve is installed.",
                          "LUTs that come with Resolve (listed in its installer receipt) are left out.",
                          "Resolve shows new LUTs after a restart or Project Settings › Color Management › Update Lists.",
                          "Additional LUT locations set in Preferences are machine paths and not restored."],
            scope: .sharedLibrary, shippedByPackage: "com.blackmagic-design.Manifest", appMustBeInstalled: true),
        AppDataProvider(
            id: "davinci-resolve-aces", appName: "DaVinci Resolve", bundleIdentifiers: resolveIDs,
            base: "Library/Application Support/Blackmagic Design/DaVinci Resolve/ACES Transforms", versionFolderPattern: nil,
            categories: [AppDataCategory("acesTransforms", "")],
            mustBeClosed: false, status: .fixtureTested, evidence: resolveEvidence, researchedOn: researchedResolve,
            limitations: ["Resolve loads ACES transforms (IDT, ODT, AMF) when it starts."]),
        AppDataProvider(
            id: "davinci-resolve-fairlight", appName: "DaVinci Resolve", bundleIdentifiers: resolveIDs,
            base: "Library/Application Support/Blackmagic Design/DaVinci Resolve/Fairlight", versionFolderPattern: nil,
            categories: [AppDataCategory("fairlightPresets", "Presets")],
            mustBeClosed: true, status: .fixtureTested, evidence: resolveEvidence, researchedOn: researchedResolve,
            limitations: ["Plug-in scans, monitoring and control-surface settings are hardware-specific and never copied."]),
        AppDataProvider(
            id: "davinci-resolve-preferences", appName: "DaVinci Resolve", bundleIdentifiers: resolveIDs,
            base: "Library/Preferences/Blackmagic Design/DaVinci Resolve", versionFolderPattern: nil,
            categories: [AppDataCategory("keyboardPresets", "", files: ["keyboard.preset.xml"]),
                         AppDataCategory("layoutPresets", "", files: ["UI.preset"]),
                         AppDataCategory("userPreferencePresets", "", files: ["config.user.presets.xml"]),
                         AppDataCategory("smartBins", "", files: ["usersmartfolder.xml", "usersmartfilter.xml"]),
                         AppDataCategory("metadataPresets", "", files: ["mediametadata.preset.xml", "primaryhdr.preset.xml"]),
                         // User preferences also hold absolute paths (project backups, last project).
                         AppDataCategory("userPreferences", "", files: ["config.user.xml"], .compatibilitySensitive)],
            mustBeClosed: true, status: .fixtureTested, evidence: resolveEvidence, researchedOn: researchedResolve,
            limitations: ["Resolve rewrites these files when it quits, so it must be closed.",
                          "Each file holds all presets of its kind and carries Resolve's database version: restored only into the same or a newer Resolve.",
                          "System preferences (config.dat: GPU, video I/O, media storage, scripting), the project library list and the licence are never copied.",
                          "PowerGrades, render presets and project presets are stored in the project library; see the guidance."],
            appMustBeInstalled: true, notForOlderApp: true),
        AppDataProvider(
            id: "blender", appName: "Blender", bundleIdentifiers: ["org.blenderfoundation.blender"],
            base: "Library/Application Support/Blender", versionFolderPattern: #"^\d+\.\d+$"#,
            categories: [AppDataCategory("preferences", "config", files: ["userpref.blend", "startup.blend", "bookmarks.txt"]),
                         AppDataCategory("presets", "scripts/presets"),
                         AppDataCategory("addons", "scripts/addons", .compatibilitySensitive),
                         AppDataCategory("extensions", "extensions", .compatibilitySensitive)],
            mustBeClosed: true, status: .fixtureTested,
            evidence: [Evidence(title: "Blender Manual: Blender's directory layout",
                                url: "https://docs.blender.org/manual/en/latest/advanced/blender_directory_layout.html")],
            researchedOn: researched,
            limitations: ["Restored into the original version folder; a newer Blender offers to import it on first launch.",
                          "Older add-ons may not load in newer Blender versions."]),
        AppDataProvider(
            id: "after-effects", appName: "Adobe After Effects", bundleIdentifiers: ["com.adobe.AfterEffects"],
            base: "Library/Preferences/Adobe/After Effects", versionFolderPattern: #"^\d+(\.\d+)*$"#,
            categories: [AppDataCategory("shortcuts", "aeks", .compatibilitySensitive),
                         AppDataCategory("workspaces", "ModifiedWorkspaces", .compatibilitySensitive)],
            mustBeClosed: true, status: .fixtureTested,
            evidence: [Evidence(title: "Adobe: After Effects preferences", url: "https://helpx.adobe.com/after-effects/using/preferences.html")],
            researchedOn: researched,
            limitations: ["After Effects can migrate previous-version preferences itself (Preferences › Startup & Repair)."]),

        // MARK: Productivity
        AppDataProvider(
            id: "keyboard-maestro", appName: "Keyboard Maestro",
            bundleIdentifiers: ["com.stairways.keyboardmaestro.editor", "com.stairways.keyboardmaestro.engine"],
            base: "Library/Application Support/Keyboard Maestro", versionFolderPattern: nil,
            categories: [AppDataCategory("macros", "", .mayContainSecrets)],
            mustBeClosed: true, status: .fixtureTested,
            evidence: [Evidence(title: "Keyboard Maestro Wiki: Frequently Asked Questions (transferring to a new Mac)",
                                url: "https://wiki.keyboardmaestro.com/Frequently_Asked_Questions")],
            researchedOn: researched,
            limitations: ["The licence (in Preferences) is not copied.",
                          "If both Macs stay in use with macro sync, Keyboard Maestro's MacUUID must be reset (see the vendor FAQ)."]),
        AppDataProvider(
            id: "alfred", appName: "Alfred", bundleIdentifiers: ["com.runningwithcrayons.Alfred"],
            base: "Library/Application Support/Alfred", versionFolderPattern: nil,
            categories: [AppDataCategory("preferencesBundle", "Alfred.alfredpreferences", .mayContainSecrets)],
            mustBeClosed: true, status: .fixtureTested,
            evidence: [Evidence(title: "Alfred: Disabling sync (location of Alfred.alfredpreferences)",
                                url: "https://www.alfredapp.com/help/advanced/sync/disable-sync/"),
                       Evidence(title: "Alfred: Syncing preferences", url: "https://www.alfredapp.com/help/advanced/sync/")],
            researchedOn: researched,
            limitations: ["Workflows can contain API keys, so this is off by default.",
                          "Users who already sync Alfred preferences should point the new Mac to the sync folder instead.",
                          "The Powerpack licence must be entered again."]),
    ]

    static let researchedPS = "2026-10-03"
    static let researchedResolve = "2026-10-03"
    static let resolveIDs = ["com.blackmagic-design.DaVinciResolve", "com.blackmagic-design.DaVinciResolveLite"]
    static let resolveEvidence = [
        Evidence(title: "DaVinci Resolve 21.1 Reference Manual (LUT folder p. 3484/4328, keyboard presets p. 122–124, layouts p. 60, Gallery p. 3342–3347, project libraries p. 4225–4227)",
                 url: "https://www.blackmagicdesign.com/support/family/davinci-resolve-and-fusion"),
        Evidence(title: "DaVinci Resolve: Technical Documentation › User Configuration folders and customization (ships with Resolve)",
                 url: "https://www.blackmagicdesign.com/support/family/davinci-resolve-and-fusion"),
    ]
    static let photoshopEvidence = [
        Evidence(title: "Adobe: Back up and restore Photoshop preferences",
                 url: "https://helpx.adobe.com/photoshop/desktop/get-started/settings-and-preferences/backup-and-restore-preferences.html"),
        Evidence(title: "Adobe: Migrate presets (files that can be copied from one installation to another)",
                 url: "https://helpx.adobe.com/photoshop/using/preset-migration.html"),
        Evidence(title: "Adobe: Photoshop beta – separate preferences", url: "https://helpx.adobe.com/photoshop/desktop/whats-new/photoshop-desktop-beta-overview.html"),
    ]

    /// `~/Library/Application Support/Adobe/<Photoshop>/Presets`: files the user saved from the panels. Adobe
    /// names this folder as the place presets are saved to and loaded from; the files work in later versions.
    static func photoshopPresets(id: String, appName: String, folderPattern: String) -> AppDataProvider {
        let folders = [("actions", "Actions"), ("brushes", "Brushes"), ("styles", "Styles"), ("gradients", "Gradients"),
                       ("patterns", "Patterns"), ("swatches", "Color Swatches"), ("shapes", "Custom Shapes"),
                       ("shortcuts", "Keyboard Shortcuts"), ("toolPresets", "Tools"), ("contours", "Contours"),
                       ("menuCustomization", "Menu Customization"), ("customToolbars", "Custom Toolbars"),
                       ("curvesPresets", "Curves"), ("levelsPresets", "Levels"), ("hueSaturationPresets", "Hue and Saturation"),
                       ("blackWhitePresets", "Black and White"), ("channelMixerPresets", "Channel Mixer"),
                       ("exposurePresets", "Exposure"), ("selectiveColorPresets", "Selective Color"), ("duotonePresets", "Duotones")]
        return AppDataProvider(
            id: id, appName: appName, bundleIdentifiers: ["com.adobe.Photoshop"],
            base: "Library/Application Support/Adobe", versionFolderPattern: folderPattern,
            categories: folders.map { AppDataCategory($0.0, "Presets/" + $0.1, movesBetweenVersions: true) },
            mustBeClosed: true, status: .fixtureTested, evidence: photoshopEvidence, researchedOn: researchedPS,
            limitations: ["Files in Presets are offered in the panel menus; they are not loaded into the panels automatically.",
                          "AutoRecover, font caches and downloaded modules next to Presets are never copied.",
                          "Adobe pages could only be read through search excerpts."])
    }

    /// `~/Library/Preferences/<Photoshop> Settings`: the panel contents, workspaces and preferences.
    static func photoshopSettings(id: String, appName: String, folderPattern: String) -> AppDataProvider {
        AppDataProvider(
            id: id, appName: appName, bundleIdentifiers: ["com.adobe.Photoshop"],
            base: "Library/Preferences", versionFolderPattern: folderPattern,
            categories: [
                // Exactly the files Adobe lists as copyable "from one installation to another".
                AppDataCategory("panelsAndWorkspaces", "", files: ["Actions Palette.psp", "Brushes.psp", "Swatches.psp", "Gradients.psp",
                                                                 "Patterns.psp", "Styles.psp", "CustomShapes.psp", "Contours.psp",
                                                                 "Default Type Styles.psp", "ToolPresets.psp"],
                                movesBetweenVersions: true),
                AppDataCategory("colorSettings", "", files: ["Color Settings.csf"], movesBetweenVersions: true),
                AppDataCategory("workspaces", "WorkSpaces", .compatibilitySensitive),
                AppDataCategory("modifiedWorkspaces", "WorkSpaces (Modified)", .compatibilitySensitive),
                AppDataCategory("workspaceState", "", files: ["Workspace Prefs.psp"], .compatibilitySensitive),
                AppDataCategory("documentPresets", "", files: ["New Doc Sizes.json", "Favorite New Doc Sizes.json"], .compatibilitySensitive),
                // The Preferences dialog; contains paths (scratch disks, plug-ins), so only for the same version.
                AppDataCategory("generalPreferences", "", files: ["{folder} Prefs.psp"], .compatibilitySensitive),
            ],
            mustBeClosed: true, status: .fixtureTested, evidence: photoshopEvidence, researchedOn: researchedPS,
            limitations: ["Photoshop saves its preferences when it quits, so it must be closed during the restore.",
                          "Machine and cache files (MachinePrefs, PluginCache, FMCache, sniffer logs, launch flags) are never copied.",
                          "Workspaces, document presets and the Preferences dialog are offered for the same Photoshop version only (not selected by default)."])
    }
}

/// Services that MacReplica detects only to tell the user what to do on the new Mac.
public enum GuidanceCatalog {
    public static let entries: [MigrationGuidance] = [
        // Developer tools with Keychain-held or device-bound logins.
        reauth("githubCLI", "GitHub CLI", paths: [".config/gh"], url: "https://cli.github.com/manual/gh_auth_login"),
        reauth("gitlabCLI", "GitLab CLI", paths: [".config/glab-cli"], url: "https://docs.gitlab.com/cli/auth/login/"),
        reauth("docker", "Docker", ids: ["com.docker.docker"], paths: [".docker/config.json"], url: "https://docs.docker.com/reference/cli/docker/login/"),
        reauth("gcloud", "Google Cloud CLI", paths: [".config/gcloud"], url: "https://docs.cloud.google.com/sdk/docs/authorizing"),
        reauth("azureCLI", "Azure CLI", paths: [".azure"], url: "https://learn.microsoft.com/en-us/cli/azure/msal-based-azure-cli"),
        reauth("awsSSO", "AWS IAM Identity Center (SSO)", paths: [".aws/sso"], url: "https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html"),
        reauth("githubDesktop", "GitHub Desktop", ids: ["com.github.GitHubClient"],
               url: "https://docs.github.com/en/desktop/installing-and-authenticating-to-github-desktop/authenticating-to-github-in-github-desktop"),
        // Apps and services whose sign-in is tied to the device.
        reauth("adobeCC", "Adobe Creative Cloud", ids: ["com.adobe.acc.AdobeCreativeCloud"],
               url: "https://helpx.adobe.com/download-install/apps/troubleshoot/licensing-activation-issues/device-activation-limit-reached.html"),
        reauth("microsoft365", "Microsoft 365", ids: ["com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.microsoft.Outlook"],
               url: "https://support.microsoft.com/en-us/accounts-billing/subscriptions/sign-in-to-microsoft-365"),
        reauth("dropbox", "Dropbox", ids: ["com.getdropbox.dropbox"], url: "https://help.dropbox.com/account-access/computer-limit"),
        reauth("onedrive", "OneDrive", ids: ["com.microsoft.OneDrive"],
               url: "https://support.microsoft.com/en-us/onedrive/sync-your-computer-s-files-and-folders-with-onedrive"),
        reauth("googleDrive", "Google Drive", ids: ["com.google.drivefs"], url: "https://support.google.com/drive/answer/10838124"),
        reauth("slack", "Slack", ids: ["com.tinyspeck.slackmacgap"], url: "https://slack.com/help/articles/212681477-Sign-in-to-Slack"),
        reauth("teams", "Microsoft Teams", ids: ["com.microsoft.teams2"],
               url: "https://learn.microsoft.com/en-us/troubleshoot/microsoftteams/teams-administration/clear-teams-cache"),
        reauth("zoom", "Zoom", ids: ["us.zoom.xos"], url: "https://support.zoom.com/hc/en/article?id=zm_kb&sysparm_article=KB0060612"),
        reauth("things", "Things", ids: ["com.culturedcode.ThingsMac"], url: "https://culturedcode.com/things/support/articles/2803570/"),
        // Apps with their own export or sync, which is more reliable than copying files.
        manual("raycast", "Raycast", ids: ["com.raycast.macos"], url: "https://manual.raycast.com/import-export"),
        manual("betterTouchTool", "BetterTouchTool", ids: ["com.hegenberg.BetterTouchTool"], url: "https://docs.folivora.ai/docs/5_restoring_automatic_backups.html"),
        manual("hazel", "Hazel", ids: ["com.noodlesoft.Hazel"],
               url: "https://www.noodlesoft.com/manual/hazel/work-with-folders-rules/manage-rules/export-rules/"),
        manual("rectangle", "Rectangle", ids: ["com.knollsoft.Rectangle"], url: "https://github.com/rxhanson/Rectangle"),
        manual("terminal", "Terminal", paths: ["Library/Preferences/com.apple.Terminal.plist"],
               url: "https://support.apple.com/guide/terminal/import-and-export-terminal-profiles-trml4299c696/mac"),
        manual("affinity", "Affinity", ids: ["com.seriflabs.affinityphoto2", "com.seriflabs.affinitydesigner2", "com.seriflabs.affinitypublisher2"],
               url: "https://affinity.help/photo2/English.lproj/pages/Addons/exportingAddons.html"),
        manual("premierePro", "Adobe Premiere Pro", ids: ["com.adobe.PremierePro"],
               url: "https://helpx.adobe.com/premiere/desktop/get-started/keyboard-shortcuts/copy-keyboard-shortcuts-from-one-computer-to-another.html"),
        manual("resolveLibrary", "DaVinci Resolve (PowerGrades, render and project presets, projects)",
               ids: ["com.blackmagic-design.DaVinciResolve", "com.blackmagic-design.DaVinciResolveLite"],
               url: "https://documents.blackmagicdesign.com/UserManuals/DaVinci_Resolve_20_Reference_Manual.pdf"),
    ]

    static func reauth(_ id: String, _ name: String, ids: [String] = [], paths: [String] = [], url: String) -> MigrationGuidance {
        MigrationGuidance(id: id, name: name, kind: .reauthenticationRequired, bundleIdentifiers: ids, paths: paths,
                          evidence: [Evidence(title: name, url: url)])
    }

    static func manual(_ id: String, _ name: String, ids: [String] = [], paths: [String] = [], url: String) -> MigrationGuidance {
        MigrationGuidance(id: id, name: name, kind: .manualMigration, bundleIdentifiers: ids, paths: paths,
                          evidence: [Evidence(title: name, url: url)])
    }
}
