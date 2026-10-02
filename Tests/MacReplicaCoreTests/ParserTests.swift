import CryptoKit
import Foundation
import Testing
@testable import MacReplicaCore
import MacReplicaTestSupport

/// Exact-output tests for the parsers that turn untrusted files into manifest data.
@Suite("Git configuration sanitizer")
struct GitConfigSanitizerTests {
    private var layout: SystemLayout {
        var layout = SystemLayout.live()
        layout.homeDirectory = URL(fileURLWithPath: "/Users/jane")
        return layout
    }

    @Test func keepsOnlyHarmlessSettingsExactly() {
        let input = """
        stray = before any section
        # comment
        ; another comment

        [user]
        \tname = Example Person
        \temail = person@example.com
        \tsigningkey = ABCDEF
        [core]
        \texcludesfile = /Users/jane/.gitignore_global
        \tbare
        [credential]
        \thelper = osxkeychain
        \tusername = example
        [credential "https://git.example.com"]
        \thelper = store
        [url "https://token@git.example.com/"]
        \tinsteadOf = https://git.example.com/
        [remote "origin"]
        \turl = https://git.example.com/x.git
        [alias]
        \tpull-all = !git pull https://user@git.example.com/repo
        \tst = status -sb
        [http]
        \textraHeader = Authorization: secret
        [empty]
        [init]
        """
        let result = DeveloperSettingsScanner.sanitize(input, includeEmail: false, layout: layout)
        #expect(result.text == """
        [user]
        \tname = Example Person
        [core]
        \texcludesfile = ~/.gitignore_global
        \tbare
        [credential]
        \thelper = osxkeychain
        [alias]
        \tst = status -sb

        """)
        #expect(result.hasEmail == false)
        #expect(result.removed == ["credential", "empty", "http", "remote", "url"])
    }

    @Test func emailOnlyWhenChosen() {
        let input = "[user]\n\temail = person@example.com\n"
        let with = DeveloperSettingsScanner.sanitize(input, includeEmail: true, layout: layout)
        #expect(with.text == "[user]\n\temail = person@example.com\n")
        #expect(with.hasEmail)
        let without = DeveloperSettingsScanner.sanitize(input, includeEmail: false, layout: layout)
        #expect(without.text == "")
        #expect(!without.hasEmail)
    }

    @Test func emptyAndDecodedSettings() throws {
        #expect(DeveloperSettings().isEmpty)
        #expect(!DeveloperSettings(gitConfig: "[user]\n").isEmpty)
        #expect(!DeveloperSettings(editorExtensions: ["Cursor": ["a.b"]]).isEmpty)
        let decoded = try JSONDecoder().decode(DeveloperSettings.self, from: Data("{}".utf8))
        #expect(decoded == DeveloperSettings())
        #expect(decoded.gitConfigIncludesEmail == false)
    }

    @Test func scanReadsGitConfigAndEditorExtensions() throws {
        let sandbox = try Sandbox("git-scan")
        var layout = SystemLayout.live()
        layout.homeDirectory = sandbox.url
        _ = try sandbox.write("[user]\n\tname = A\n\temail = a@example.com\n", to: ".gitconfig")
        _ = try sandbox.folder(".vscode/extensions/ms-python.python-2024.1.0")
        _ = try sandbox.folder(".vscode/extensions/ms-python.python-2024.2.0")
        _ = try sandbox.folder(".cursor/extensions")
        let scanned = DeveloperSettingsScanner(layout: layout).scan()
        #expect(scanned.gitConfigIncludesEmail, "the email is included unless the caller opts out")
        #expect(scanned.editorExtensions == ["Visual Studio Code": ["ms-python.python"]], "editors without extensions are not listed")
        #expect(DeveloperSettingsScanner(layout: layout).scan(includeEmail: false).gitConfig == "[user]\n\tname = A\n")
    }
}

@Suite("ICC header parser")
struct ICCHeaderTests {
    private func profile(_ edit: (inout [UInt8]) -> Void = { _ in }) -> Data {
        var bytes = [UInt8](SimulationBuilder.makeICCProfile(description: "Header Test", creator: "TEST"))
        edit(&bytes)
        return Data(bytes)
    }

    @Test func readsIdentityFields() throws {
        let data = profile { b in
            b.replaceSubrange(48..<52, with: Array("EXMP".utf8))          // manufacturer
            b.replaceSubrange(52..<56, with: [0, 0, 0x12, 0x34])           // numeric model
            b.replaceSubrange(24..<36, with: [0x07, 0xEA, 0, 10, 0, 2, 0, 18, 0, 52, 0, 9]) // 2026-10-02 18:52:09
            b.replaceSubrange(84..<100, with: Array(repeating: 0xAB, count: 16))
        }
        let header = try #require(ICCProfileHeader.parse(data))
        #expect(header.creator == "TEST")
        #expect(header.manufacturer == "EXMP")
        #expect(header.model == "00001234", "non-text signatures are shown as hex")
        #expect(header.created == "2026-10-02T18:52:09Z")
        #expect(header.profileID == String(repeating: "ab", count: 16))
        #expect(header.description == "Header Test")
    }

    @Test func emptyFieldsAreNil() throws {
        let header = try #require(ICCProfileHeader.parse(profile { b in b.replaceSubrange(80..<84, with: [0, 0, 0, 0]) }))
        #expect(header.creator == nil)
        #expect(header.manufacturer == nil)
        #expect(header.model == nil)
        #expect(header.created == nil)
        #expect(header.profileID == nil)
        // A partially set Profile ID is still an ID.
        #expect(ICCProfileHeader.parse(profile { b in b[99] = 1 })?.profileID == String(repeating: "0", count: 30) + "01")
    }

    @Test func invalidDatesAreIgnored() {
        func created(_ date: [UInt8]) -> String? { ICCProfileHeader.parse(profile { b in b.replaceSubrange(24..<36, with: date) })?.created }
        #expect(created([0x07, 0x6B, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0]) == nil, "year 1899")
        #expect(created([0x07, 0x6C, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0]) == "1900-01-01T00:00:00Z")
        #expect(created([0x07, 0xEA, 0, 13, 0, 1, 0, 0, 0, 0, 0, 0]) == nil, "month 13")
        #expect(created([0x07, 0xEA, 0, 12, 0, 32, 0, 0, 0, 0, 0, 0]) == nil, "day 32")
        #expect(created([0x07, 0xEA, 0, 12, 0, 31, 0, 0, 0, 0, 0, 0]) == "2026-12-31T00:00:00Z")
    }

    @Test func computedProfileIDIgnoresOnlyFlagsIntentAndStoredID() {
        let base = profile()
        let id = ICCProfileHeader.computedProfileID(base)
        var md5Input = [UInt8](base)
        for index in Array(44..<48) + Array(64..<68) + Array(84..<100) { md5Input[index] = 0 }
        #expect(id == Insecure.MD5.hash(data: md5Input).map { String(format: "%02x", $0) }.joined())
        #expect(ICCProfileHeader.computedProfileID(profile { b in b[44] = 1; b[67] = 3; b[90] = 7 }) == id)
        #expect(ICCProfileHeader.computedProfileID(profile { b in b[43] = 1 }) != id)
        #expect(ICCProfileHeader.computedProfileID(profile { b in b[48] = 1 }) != id)
        #expect(ICCProfileHeader.computedProfileID(profile { b in b[100] = 1 }) != id)
        // Short data: the fields that exist are zeroed, nothing crashes.
        let short = Data(base.prefix(70))
        var shortInput = [UInt8](short)
        for index in Array(44..<48) + Array(64..<68) { shortInput[index] = 0 }
        #expect(ICCProfileHeader.computedProfileID(short) == Insecure.MD5.hash(data: shortInput).map { String(format: "%02x", $0) }.joined())
        let exactlyHeaderID = Data(base.prefix(100))
        var exactInput = [UInt8](exactlyHeaderID)
        for index in Array(44..<48) + Array(64..<68) + Array(84..<100) { exactInput[index] = 0 }
        #expect(ICCProfileHeader.computedProfileID(exactlyHeaderID) == Insecure.MD5.hash(data: exactInput).map { String(format: "%02x", $0) }.joined())
    }

    @Test func sizeBoundaries() {
        let base = profile()
        #expect(ICCProfileHeader.parse(base.prefix(132)) != nil, "a bare header with an empty tag table is valid")
        #expect(ICCProfileHeader.parse(base.prefix(131)) == nil)
        #expect(ICCProfileHeader.profileID(Data(count: 99)) == nil)
        #expect(ICCProfileHeader.profileID(Data(repeating: 1, count: 100)) == String(repeating: "01", count: 16))
    }

    /// Builds a profile whose only tag is `tag`, placed directly after a one-entry tag table.
    private func withSingleTag(_ tag: [UInt8], declaredLength: Int? = nil, tagCount: Int = 1) -> Data {
        var bytes = [UInt8](profile().prefix(128))
        func be(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        bytes += be(tagCount) + Array("desc".utf8) + be(144) + be(declaredLength ?? tag.count)
        bytes += tag
        bytes.replaceSubrange(0..<4, with: be(bytes.count))
        return Data(bytes)
    }

    @Test func descriptionTagBoundaries() {
        func desc(_ text: String) -> [UInt8] {
            let t = Array(text.utf8) + [0]
            return Array("desc".utf8) + [0, 0, 0, 0] + [0, 0, 0, UInt8(t.count)] + t
        }
        // Text that ends exactly at the end of the file is read.
        #expect(ICCProfileHeader.parse(withSingleTag(desc("Exact")))?.description == "Exact")
        // A declared length past the end is refused.
        #expect(ICCProfileHeader.parse(withSingleTag(desc("Exact"), declaredLength: 40))?.description == nil)
        // A text count past the end is refused.
        var tooLong = desc("Exact")
        tooLong[11] = 40
        #expect(ICCProfileHeader.parse(withSingleTag(tooLong))?.description == nil)
        // Implausible tag counts are refused, plausible ones read.
        #expect(ICCProfileHeader.parse(withSingleTag(desc("Many"), tagCount: 1000))?.description == nil)
        #expect(ICCProfileHeader.parse(withSingleTag(desc("Zero"), tagCount: 0))?.description == nil)
        // A tag declared with exactly the minimum size is still read (the text count decides).
        #expect(ICCProfileHeader.parse(withSingleTag(desc("Minimum"), declaredLength: 12))?.description == "Minimum")
        // A tag shorter than its minimum size is refused.
        #expect(ICCProfileHeader.parse(withSingleTag(Array(desc("x").prefix(11))))?.description == nil)
    }

    @Test func localizedDescriptionBoundaries() {
        let text = Array("Ünï".utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        func mluc(records: UInt8 = 1, length: Int? = nil) -> [UInt8] {
            Array("mluc".utf8) + [0, 0, 0, 0] + [0, 0, 0, records] + [0, 0, 0, 12] + Array("enUS".utf8)
                + [0, 0, 0, UInt8(length ?? text.count)] + [0, 0, 0, 28] + text
        }
        #expect(ICCProfileHeader.parse(withSingleTag(mluc()))?.description == "Ünï", "record ends exactly at the end")
        #expect(ICCProfileHeader.parse(withSingleTag(mluc(records: 0)))?.description == nil)
        #expect(ICCProfileHeader.parse(withSingleTag(mluc(length: text.count + 2)))?.description == nil)
        #expect(ICCProfileHeader.parse(withSingleTag(mluc(length: 0)))?.description == nil)
    }

    @Test func signaturesWithControlCharactersBecomeHex() throws {
        let header = try #require(ICCProfileHeader.parse(profile { b in b.replaceSubrange(80..<84, with: [0x41, 0x01, 0x42, 0x43]) }))
        #expect(header.creator == "41014243")
        #expect(ICCProfileHeader.parse(profile { b in b.replaceSubrange(80..<84, with: Array("ab c".utf8)) })?.creator == "ab c")
        #expect(ICCProfileHeader.parse(profile { b in b.replaceSubrange(80..<84, with: [0x20, 0x20, 0x20, 0x20]) })?.creator
                == "20202020", "only spaces is not a readable signature")
    }
}
