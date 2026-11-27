import Foundation
import Testing

/// 检查 String Catalog 本身：每条文案都有中文、占位符对得上、编译产物能按语言查到。
/// 「代码里的文案都进了 Catalog」由 `scripts/l10n.sh check` 检查（需要带抽取参数重新编译）。
@Suite("Localization catalog")
struct LocalizationCatalogTests {
    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // AgentInboxAppTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // 仓库根目录
        .appendingPathComponent("Assets/Localization/Localizable.xcstrings")

    private static let translatedLanguage = "zh-Hans"

    private struct Catalog: Decodable {
        let sourceLanguage: String
        let strings: [String: Entry]
    }

    private struct Entry: Decodable {
        let shouldTranslate: Bool?
        let extractionState: String?
        let localizations: [String: Localization]?
    }

    private struct Localization: Decodable {
        let stringUnit: StringUnit?
        let variations: Variations?

        /// 本语言的全部译文：单一译文，或每个复数变体各一条。
        var values: [StringUnit] {
            if let stringUnit { return [stringUnit] }
            return variations?.plural?.values.compactMap(\.stringUnit) ?? []
        }
    }

    private struct Variations: Decodable {
        let plural: [String: Localization]?
    }

    private struct StringUnit: Decodable {
        let state: String
        let value: String
    }

    private static func loadCatalog() throws -> Catalog {
        try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
    }

    /// 按参数位置排好的占位符类型，如 "%1$lld 个（共 %2$lld 个）" → ["lld", "lld"]；`%%` 不算。
    private static func placeholders(in text: String) -> [String] {
        let pattern = /%(?:(\d+)\$)?(lld|ld|d|@|f)/
        var positional: [(Int, String)] = []
        for (index, match) in text.matches(of: pattern).enumerated() {
            let position = match.1.flatMap { Int($0) } ?? index + 1
            positional.append((position, String(match.2)))
        }
        return positional.sorted { $0.0 < $1.0 }.map(\.1)
    }

    @Test("source language is English")
    func sourceLanguage() throws {
        #expect(try Self.loadCatalog().sourceLanguage == "en")
    }

    @Test("every string has a Simplified Chinese translation and none is stale")
    func everyStringTranslated() throws {
        let catalog = try Self.loadCatalog()
        #expect(!catalog.strings.isEmpty)
        for (key, entry) in catalog.strings {
            #expect(entry.extractionState != "stale", "no longer in the code, delete it: \(key)")
            if entry.shouldTranslate == false { continue }
            let units = entry.localizations?[Self.translatedLanguage]?.values ?? []
            #expect(!units.isEmpty, "missing \(Self.translatedLanguage) translation: \(key)")
            for unit in units {
                #expect(unit.state == "translated", "\(Self.translatedLanguage) not translated: \(key)")
                #expect(!unit.value.isEmpty, "empty \(Self.translatedLanguage) translation: \(key)")
            }
        }
    }

    @Test("translations keep the key's placeholders")
    func placeholdersMatch() throws {
        let catalog = try Self.loadCatalog()
        for (key, entry) in catalog.strings {
            let expected = Self.placeholders(in: key)
            for (language, localization) in entry.localizations ?? [:] {
                for unit in localization.values {
                    #expect(Self.placeholders(in: unit.value) == expected,
                            "\(language) placeholders differ for \(key): \(unit.value)")
                }
            }
        }
    }

    /// 走一遍打包时的编译步骤，确认 .lproj 产物按语言查得到，英文复数规则也生效。
    @Test("compiled catalog resolves per language")
    func compiledLookup() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-inbox-l10n-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }

        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compile.arguments = ["xcstringstool", "compile", Self.catalogURL.path, "--output-directory", output.path]
        compile.standardOutput = FileHandle.nullDevice
        try compile.run()
        compile.waitUntilExit()
        try #require(compile.terminationStatus == 0)

        let chinese = try #require(Bundle(url: output.appendingPathComponent("zh-Hans.lproj")))
        #expect(chinese.localizedString(forKey: "New List", value: nil, table: nil) == "新建清单")
        let todos = chinese.localizedString(forKey: "%lld todos", value: nil, table: nil)
        #expect(String.localizedStringWithFormat(todos, 3) == "3 个待办")

        let english = try #require(Bundle(url: output.appendingPathComponent("en.lproj")))
        let englishTodos = english.localizedString(forKey: "%lld todos", value: nil, table: nil)
        #expect(String.localizedStringWithFormat(englishTodos, 1) == "1 todo")
        #expect(String.localizedStringWithFormat(englishTodos, 2) == "2 todos")
    }
}
