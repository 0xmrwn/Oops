import Foundation
@testable import Oops
import Testing

@MainActor struct StatsLoadingTests {
    @Test func `word counts use whitespace and newline character boundaries`() {
        #expect(Stats.words(in: "") == 0)
        #expect(Stats.words(in: " \t\r\n\u{00A0}\u{2028}\u{2029}") == 0)
        #expect(Stats.words(in: "  one-two\tcan't\r\nthree  ") == 3)
        #expect(Stats.words(in: "cafe\u{0301}\u{00A0}👩🏽‍💻\u{2028}مرحبا") == 3)
        #expect(Stats.words(in: "two\u{200B}words") == 1)
    }

    @Test(arguments: Case.allCases)
    func `loading synthetic JSONL preserves the existing events and line boundaries`(_ variant: Case) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try variant.data.write(to: fixture.file)
        let expected = legacyLoad(fixture.file), actual = Stats.load(fixture.file)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .millisecondsSince1970
        #expect(try encoder.encode(actual) == encoder.encode(expected))
        #expect(actual.count == variant.count)
    }

    @Test func `missing history loads no events without creating a file`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(Stats.load(fixture.file).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
    }

    @Test func `all outcomes and distinct fields retain order across many rows`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outcomes: [Stats.Event.Outcome] = [.fixed, .clear, .reverted, .reapplied, .failed]
        let expected = (0..<770).map { index in
            Stats.Event(date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 67)), outcome: outcomes[index % 5],
                        words: index, fixes: index % 9, seconds: index.isMultiple(of: 3) ? nil : Double(index) / 10,
                        model: index.isMultiple(of: 4) ? nil : "Synthetic-\(index)", app: "Synthetic é 👋")
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for (index, event) in expected.enumerated() {
            data.append(try encoder.encode(event)); data.append(10)
            if index.isMultiple(of: 250) { data.append(Data("partial{\nnull\n".utf8)) }
        }
        try data.write(to: fixture.file)
        #expect(try encoder.encode(Stats.load(fixture.file)) == encoder.encode(expected))
    }

    @Test func `records before the first history read appear once and in order`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Case.lf.data.write(to: fixture.file)
        let stats = Stats(file: fixture.file)
        stats.record(.init(date: .now, outcome: .clear, words: 15))
        Stats(file: fixture.file).record(.init(date: .now, outcome: .reapplied))
        stats.record(.init(date: .now, outcome: .fixed, words: 21, fixes: 4))
        #expect(stats.events.map(\.outcome) == [.fixed, .reverted, .clear, .fixed])
        #expect(stats.wordsChecked == 76)
        #expect(stats.mistakesFixed == 6)
        #expect(Stats.load(fixture.file).map(\.outcome) == [.fixed, .reverted, .clear, .reapplied, .fixed])

        stats.record(.init(date: .now, outcome: .clear))
        #expect(stats.corrections == 4)
        try stats.reset()
        #expect(stats.events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.file.path))
    }

    @Test func `a failed append before the first read still counts for this session`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: false)
        let stats = Stats(file: fixture.file)
        stats.record(.init(date: .now, outcome: .clear))
        try FileManager.default.removeItem(at: fixture.file)
        stats.record(.init(date: .now, outcome: .fixed, fixes: 2))
        #expect(stats.events.map(\.outcome) == [.clear, .fixed])
        #expect(Stats.load(fixture.file).map(\.outcome) == [.fixed])
    }

    /// Frozen pre-optimization behavior: byte framing must not broaden what a line can decode.
    private func legacyLoad(_ file: URL) -> [Stats.Event] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(Stats.Event.self, from: Data($0.utf8)) }
    }

    enum Case: CaseIterable {
        case empty, lf, noFinalNewline, crlf, mixedLineEndings, carriageReturnSpace, whitespace
        case fileBOM, innerBOM, malformed, twoObjectsWithComma, twoObjectsWithoutComma, dateOffset
        case fractionalDate, nullOptional, missingDefaults, unknownOutcome, jsonArray, invalidUTF8

        var count: Int {
            switch self {
            case .lf, .noFinalNewline, .carriageReturnSpace, .whitespace, .fileBOM, .innerBOM, .malformed: 2
            case .dateOffset, .fractionalDate, .nullOptional: 1
            default: 0
            }
        }

        var data: Data {
            let x = #"{"date":"2023-11-14T22:13:20Z","outcome":"fixed","words":40,"fixes":2,"seconds":1,"model":"Synthetic\n\"é 👋\""}"#
            let y = #"{"date":"2023-11-14T22:14:27Z","outcome":"reverted","words":3,"fixes":0,"app":"Synthetic"}"#
            let text: String
            switch self {
            case .empty: text = ""
            case .lf: text = x + "\n" + y + "\n"
            case .noFinalNewline: text = x + "\n" + y
            case .crlf: text = x + "\r\n" + y + "\r\n"
            case .mixedLineEndings: text = x + "\r\n" + y + "\n"
            case .carriageReturnSpace: text = x + "\r \n" + y
            case .whitespace: text = "\n \n\t" + x + "  \n\n" + y + "\n"
            case .fileBOM: text = "\u{FEFF}" + x + "\n" + y
            case .innerBOM: text = x + "\n\u{FEFF}" + y
            case .malformed: text = "invalid\n" + x + "\n{}\nnull\n[]\n" + y + "\npartial{"
            case .twoObjectsWithComma: text = x + "," + y
            case .twoObjectsWithoutComma: text = x + y
            case .dateOffset: text = x.replacingOccurrences(of: "2023-11-14T22:13:20Z", with: "2023-11-14T23:13:20+01:00")
            case .fractionalDate: text = x.replacingOccurrences(of: "2023-11-14T22:13:20Z", with: "2023-11-14T22:13:20.123Z")
            case .nullOptional: text = x.dropLast() + ",\"app\":null}"
            case .missingDefaults: text = #"{"date":"2023-11-14T22:13:20Z","outcome":"fixed"}"#
            case .unknownOutcome: text = x.replacingOccurrences(of: "\"fixed\"", with: "\"unknown\"")
            case .jsonArray: text = "[" + x + "," + y + "]"
            case .invalidUTF8: return Data(x.utf8) + Data([10, 0xFF, 10]) + Data(y.utf8)
            }
            return Data(text.utf8)
        }
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oops-stats-test-\(UUID())", isDirectory: true)
        var file: URL { root.appendingPathComponent("synthetic.jsonl") }
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
