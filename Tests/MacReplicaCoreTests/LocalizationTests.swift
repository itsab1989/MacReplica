import Foundation
import Testing
@testable import MacReplicaCore

@Suite("Localization")
struct LocalizationTests {
    static let folder = LocalizationResources.folder
    static func table(_ language: AppLanguage) -> [String: String] { Localizer.loadTable(language: language, resourcesFolder: folder) }
    static let english = table(.english)

    static func placeholders(_ text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(\d+\$)?[@dDfsu]"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range, in: text)!]) }.sorted()
    }

    @Test func englishIsLoadedAndSubstantial() {
        #expect(Self.english.count > 300)
        #expect(Self.english["home.inventory.title"] == "Create Backup")
    }

    @Test(arguments: AppLanguage.allCases)
    func everyLanguageIsComplete(_ language: AppLanguage) {
        let table = Self.table(language)
        let missing = Set(Self.english.keys).subtracting(table.keys)
        let extra = Set(table.keys).subtracting(Self.english.keys)
        #expect(missing.isEmpty, "\(language.rawValue) is missing \(missing.sorted())")
        #expect(extra.isEmpty, "\(language.rawValue) has unknown keys \(extra.sorted())")
        let empty = table.filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }.keys
        #expect(empty.isEmpty, "\(language.rawValue) has empty values \(empty.sorted())")
    }

    @Test(arguments: AppLanguage.allCases)
    func placeholdersMatchEnglish(_ language: AppLanguage) {
        let table = Self.table(language)
        for (key, english) in Self.english {
            guard let translated = table[key] else { continue }
            #expect(Self.placeholders(translated) == Self.placeholders(english), "\(language.rawValue): \(key)")
            // Every placeholder must be positional so translations can reorder them.
            for placeholder in Self.placeholders(translated) {
                #expect(placeholder.contains("$"), "\(language.rawValue): \(key) uses non-positional \(placeholder)")
            }
        }
    }

    @Test(arguments: AppLanguage.allCases)
    func formattingNeverCrashesAndKeepsValues(_ language: AppLanguage) {
        let localizer = Localizer(language: language)
        for key in Self.english.keys where !key.hasSuffix(".one") && !key.hasSuffix(".other") {
            let types = Self.placeholders(Self.english[key]!).map { $0.hasSuffix("d") ? "d" : "@" }
            let positions = Self.placeholders(Self.english[key]!).compactMap { p -> Int? in Int(p.dropFirst().prefix { $0.isNumber }) }
            guard !types.isEmpty else {
                #expect(!localizer.t(key).isEmpty)
                continue
            }
            var arguments: [CVarArg] = []
            for position in 1...(positions.max() ?? 0) {
                let index = positions.firstIndex(of: position)!
                arguments.append(types[index] == "d" ? 7 : "VALUE")
            }
            let text = String(format: localizer.t(key), locale: language.locale, arguments: arguments)
            #expect(!text.contains("%"), "\(language.rawValue): \(key) left a placeholder: \(text)")
            if types.contains("@") { #expect(text.contains("VALUE"), "\(language.rawValue): \(key)") }
        }
    }

    @Test func pluralKeysComeInPairs() {
        let plurals = Self.english.keys.filter { $0.hasSuffix(".one") }.map { String($0.dropLast(4)) }
        #expect(plurals.count > 10)
        for key in plurals {
            #expect(Self.english[key + ".other"] != nil, "\(key)")
        }
    }

    @Test func pluralRules() {
        #expect(AppLanguage.english.pluralCategory(1) == "one")
        #expect(AppLanguage.english.pluralCategory(0) == "other")
        #expect(AppLanguage.german.pluralCategory(2) == "other")
        #expect(AppLanguage.french.pluralCategory(0) == "one")
        #expect(AppLanguage.french.pluralCategory(1) == "one")
        #expect(AppLanguage.french.pluralCategory(2) == "other")
        let english = Localizer(language: .english)
        #expect(english.p("results.subtitle", 1) == "1 application found")
        #expect(english.p("results.subtitle", 47) == "47 applications found")
        let german = Localizer(language: .german)
        #expect(german.p("results.subtitle", 1) != german.p("results.subtitle", 2).replacingOccurrences(of: "2", with: "1"))
    }

    @Test func missingTranslationsFallBackToEnglishAndNeverShowKeys() {
        let localizer = Localizer(language: .german, table: ["common.back": "Zurück"], fallback: ["common.back": "Back", "common.done": "Done",
                                                                                                    "x.one": "%1$d thing", "x.other": "%1$d things"])
        #expect(localizer.t("common.back") == "Zurück")
        #expect(localizer.t("common.done") == "Done")
        #expect(localizer.t("does.not.exist") == "…")
        #expect(localizer.p("x", 3) == "3 things")
        #expect(localizer.p("nothing", 3) == "…")
        #expect(!localizer.hasTranslation("common.done"))
        let empty = Localizer(language: .german, table: ["common.back": ""], fallback: ["common.back": "Back"])
        #expect(empty.t("common.back") == "Back", "empty translations fall back too")
    }

    @Test func everyKeyUsedInTheCodeExists() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let regex = try NSRegularExpression(pattern: #"\b([tp])\("([a-zA-Z0-9_.]+)""#)
        var used: [(String, String)] = []
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                used.append((String(text[Range(match.range(at: 1), in: text)!]), String(text[Range(match.range(at: 2), in: text)!])))
            }
        }
        // Keys passed around in arrays, e.g. the steps of the restore instructions.
        let listed = try NSRegularExpression(pattern: #""((?:guide|saved\.transfer)\.[a-zA-Z0-9.]+)""#)
        let enumerator2 = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let url as URL in enumerator2 where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in listed.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                used.append(("l", String(text[Range(match.range(at: 1), in: text)!])))
            }
        }
        for reason in [BackupIssue.Reason.unreadable, .refusedSensitive, .tooLarge, .changedDuringBackup] {
            #expect(Self.english["backupIssue.\(reason.rawValue)"] != nil)
        }
        for stage in StartupStage.allCases { #expect(Self.english["startup.stage.\(stage.rawValue)"] != nil) }
        #expect(used.count > 250)
        for (kind, key) in used {
            if kind == "l" {
                #expect(Self.english[key] != nil || Self.english[key + ".one"] != nil, "missing key \(key)")
            } else if kind == "p" {
                #expect(Self.english[key + ".one"] != nil && Self.english[key + ".other"] != nil, "plural \(key)")
            } else {
                #expect(Self.english[key] != nil, "missing key \(key)")
            }
        }
        // Keys built at runtime.
        for phase in InventoryPhase.allCases { #expect(Self.english["scan.phase.\(phase.rawValue)"] != nil) }
        for category in FailureCategory.allCases {
            #expect(Self.english["failure.\(category.rawValue).title"] != nil)
            #expect(Self.english["failure.\(category.rawValue).explanation"] != nil)
        }
    }

    @Test(arguments: AppLanguage.allCases)
    func descriptionsAreTranslatedForEveryCase(_ language: AppLanguage) {
        let l = Localizer(language: language)
        var texts: [String] = []
        texts += RestoreComponent.allCases.flatMap { [l.componentText($0), l.componentHint($0)] }
        texts += RestoreCategory.allCases.map(l.categoryText)
        texts += FailureCategory.allCases.flatMap { [l.failureTitle($0), l.failureExplanation($0)] }
        texts += [RestoreActivity.checking, .downloading, .installing, .copying, .verifying, .waitingForAdmin, .waitingForCommandLineTools].map(l.activityText)
        texts += [InstallSource.appStore, .homebrewCask(token: "t"), .package(identifier: "p"), .downloaded(agent: "Safari"), .unknown].map(l.sourceText)
        texts += [SkipReason.keptExisting, .userSkipped, .dependencyFailed(itemTitle: "X"), .tapNotEnabled(tap: "a/b"),
                  .incompatibleArchitecture(required: [.arm64]), .cancelled].map(l.skipText)
        texts += [Prediction.willInstall, .willCopy, .alreadyPresent(version: "1"), .alreadyPresent(version: nil), .identicalFileExists,
                  .conflict(resolution: .replace), .backupFileDamaged, .dependsOnEarlierStep].map { l.predictionText($0, kind: .cask) }
        texts += [ResultNote.requiresRosetta, .identicalFileExists, .newerVersionInstalled(original: "1", installed: "2"),
                  .existingFileMovedAside(path: "~/x")].map(l.noteText)
        texts += [VerificationIssue.checksumMissing, .checksumMismatch, .fileMissing("a"), .hashMismatch("a"), .sizeMismatch("a"),
                  .unsafePath("a"), .unsupportedVersion(found: 2, supported: 1), .manifestUnreadable("x")].map(l.verificationIssueText)
        texts += [InventoryWarning.homebrewNotInstalled, .homebrewBroken(reason: "x"), .homebrewListFailed, .masNotInstalled,
                  .masListFailed, .catalogUnavailable].map(l.inventoryWarningText)
        for text in texts {
            #expect(!text.isEmpty && text != "…" && !text.contains("%"), "\(language.rawValue): \(text)")
            #expect(text.range(of: #"^[a-z]+(\.[a-zA-Z]+)+$"#, options: .regularExpression) == nil, "raw key shown: \(text)")
        }
    }

    @Test func formattingHelpers() {
        let german = Localizer(language: .german)
        #expect(german.number(1234567) == "1.234.567")
        #expect(german.percent(0.6) == "60\u{A0}%")
        #expect(Localizer(language: .english).percent(1.5) == "100%")
        #expect(german.fileSize(1_500_000) == "1,5 MB")
        #expect(Localizer(language: .french).fileSize(2_000) == "2 ko")
        #expect(Localizer(language: .english).fileSize(512) == "512 bytes")
        #expect(Localizer(language: .english).remainingTime(30) == "less than a minute")
        #expect(Localizer(language: .english).remainingTime(60) == "about 1 minute")
        #expect(Localizer(language: .english).remainingTime(600) == "about 10 minutes")
        #expect(Localizer(language: .english).remainingTime(3600) == "about 1 hour")
        #expect(Localizer(language: .english).remainingTime(5400) == "about 1 h 30 min")
    }

    @Test func technicalIdentifiersStayUntranslated() {
        for language in AppLanguage.allCases {
            let table = Self.table(language)
            #expect(table["method.homebrewCask"]?.contains("Homebrew") == true, "\(language.rawValue)")
            #expect(table["conflict.replaceHint"]?.contains("~/Library/Application Support/MacReplica") == true, "\(language.rawValue)")
            #expect(table["about.kofi"]?.contains("MacReplica") == true && table["about.kofi"]?.contains("Ko-fi") == (language != .english), "\(language.rawValue)")
        }
    }

    @Test func languageMetadata() {
        #expect(AppLanguage.allCases.count == 7)
        #expect(AppLanguage(rawValue: "nb") == .norwegianBokmal)
        #expect(AppLanguage.norwegianBokmal.nativeName == "Norsk bokmål")
        #expect(Set(AppLanguage.allCases.map(\.nativeName)).count == 7)
    }
}
