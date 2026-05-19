//
//  HeuristicMWEDetectionServiceTests.swift
//  AidokuTests
//
//  Coverage for the Foundation Models–free MWE fallback. Uses real NLTagger
//  lemmatization (no external dependencies, deterministic per-language).
//

import Foundation
import Testing
@testable import Aidoku

@Suite struct HeuristicMWEDetectionServiceTests {

    private func page(_ bubbles: [[String]]) -> MWEDetectionPage {
        MWEDetectionPage(bubbles: bubbles.map { MWEDetectionBubble(tokens: $0) })
    }

    // MARK: — English

    @Test func english_idiom_matchesInflected() async throws {
        let detector = HeuristicMWEDetectionService()
        let input = page([["He", "kicked", "the", "bucket", "yesterday"]])
        let result = try await detector.detect(page: input, sourceLanguage: "en-US")
        let texts = result.map(\.text)
        #expect(texts.contains("kicked the bucket"))
        let first = try #require(result.first { $0.text == "kicked the bucket" })
        #expect(first.kind == .idiom)
        #expect(first.startWordIndex == 1)
        #expect(first.endWordIndex == 3)
    }

    @Test func english_phrasalVerb_separated() async throws {
        let detector = HeuristicMWEDetectionService()
        let input = page([["Please", "get", "up", "now"]])
        let result = try await detector.detect(page: input, sourceLanguage: "en-US")
        let span = try #require(result.first { $0.text == "get up" })
        #expect(span.kind == .phrasalVerb)
    }

    @Test func english_unknownText_returnsEmpty() async throws {
        let detector = HeuristicMWEDetectionService()
        let input = page([["The", "cat", "sat", "on", "the", "mat"]])
        let result = try await detector.detect(page: input, sourceLanguage: "en-US")
        #expect(result.allSatisfy { $0.kind != .idiom })
    }

    // MARK: — German

    @Test func german_idiom_basicMatch() async throws {
        let detector = HeuristicMWEDetectionService()
        let input = page([["Ich", "muss", "ins", "Bett", "gehen"]])
        let result = try await detector.detect(page: input, sourceLanguage: "de-DE")
        // "ins Bett gehen" should match given any of: lemma-equal ("in"/"bett"/"gehen") or surface ("ins"/"bett"/"gehen").
        #expect(result.contains { $0.text.lowercased().contains("bett") && $0.kind == .idiom })
    }

    // MARK: — Turkish

    @Test func turkish_idiom_stemTolerant_ortayaCikti() async throws {
        let detector = HeuristicMWEDetectionService()
        let input = page([["Birden", "ortaya", "çıktı", "adam"]])
        let result = try await detector.detect(page: input, sourceLanguage: "tr-TR")
        let span = try #require(result.first { $0.kind == .idiom && $0.text.lowercased().contains("ortaya") })
        #expect(span.startWordIndex == 1)
        #expect(span.endWordIndex == 2)
    }

    @Test func turkish_idiom_besParaEtmez() async throws {
        let detector = HeuristicMWEDetectionService()
        let input = page([["Siz", "beş", "para", "etmez", "insanlar"]])
        let result = try await detector.detect(page: input, sourceLanguage: "tr-TR")
        #expect(result.contains { $0.kind == .idiom && $0.text.lowercased().hasPrefix("beş para") })
    }

    @Test func turkish_idiom_insanMusveddeleri() async throws {
        let detector = HeuristicMWEDetectionService()
        let input = page([["Siz", "insan", "müsveddeleri", "neredesiniz"]])
        let result = try await detector.detect(page: input, sourceLanguage: "tr-TR")
        #expect(result.contains { $0.text.lowercased().contains("insan müsvedde") })
    }

    // MARK: — Empty + unsupported

    @Test func unsupportedLanguage_returnsEmpty() async throws {
        let detector = HeuristicMWEDetectionService()
        let input = page([["foo", "bar", "baz"]])
        let result = try await detector.detect(page: input, sourceLanguage: "ja-JP")
        #expect(result.isEmpty)
    }

    @Test func emptyPage_returnsEmpty() async throws {
        let detector = HeuristicMWEDetectionService()
        let result = try await detector.detect(page: MWEDetectionPage(bubbles: []), sourceLanguage: "en-US")
        #expect(result.isEmpty)
    }

    // MARK: — Composite fallback

    private struct StubDetector: MWEDetectionService {
        let result: [DetectedPhraseSpan]
        let shouldThrow: Bool
        func detect(page: MWEDetectionPage, sourceLanguage: String) async throws -> [DetectedPhraseSpan] {
            if shouldThrow { throw MWEDetectionError.unavailable }
            return result
        }
    }

    @Test func composite_primaryEmpty_callsFallback() async throws {
        let primary = StubDetector(result: [], shouldThrow: false)
        let fallback = HeuristicMWEDetectionService()
        let composite = CompositeMWEDetectionService(primary: primary, fallback: fallback)
        let input = page([["He", "kicked", "the", "bucket"]])
        let result = try await composite.detect(page: input, sourceLanguage: "en-US")
        #expect(result.contains { $0.text == "kicked the bucket" })
    }

    @Test func composite_primaryThrows_callsFallback() async throws {
        let primary = StubDetector(result: [], shouldThrow: true)
        let fallback = HeuristicMWEDetectionService()
        let composite = CompositeMWEDetectionService(primary: primary, fallback: fallback)
        let input = page([["He", "kicked", "the", "bucket"]])
        let result = try await composite.detect(page: input, sourceLanguage: "en-US")
        #expect(result.contains { $0.text == "kicked the bucket" })
    }

    @Test func composite_primaryNonEmpty_skipsFallback() async throws {
        let stubSpan = DetectedPhraseSpan(
            text: "stub",
            kind: .idiom,
            bubbleIndex: 0,
            startWordIndex: 0,
            endWordIndex: 1,
            confidence: 1.0
        )
        let primary = StubDetector(result: [stubSpan], shouldThrow: false)
        let fallback = HeuristicMWEDetectionService()
        let composite = CompositeMWEDetectionService(primary: primary, fallback: fallback)
        let input = page([["He", "kicked", "the", "bucket"]])
        let result = try await composite.detect(page: input, sourceLanguage: "en-US")
        #expect(result.count == 1)
        #expect(result[0].text == "stub")
    }

    // MARK: — Overlap resolution shared helper

    @Test func detectedPhraseSpan_resolveOverlaps_longestWins() {
        let a = DetectedPhraseSpan(text: "a b", kind: .idiom, bubbleIndex: 0, startWordIndex: 0, endWordIndex: 1, confidence: 0.5)
        let b = DetectedPhraseSpan(text: "a b c", kind: .idiom, bubbleIndex: 0, startWordIndex: 0, endWordIndex: 2, confidence: 0.5)
        let out = DetectedPhraseSpan.resolveOverlaps([a, b])
        #expect(out.count == 1)
        #expect(out[0].endWordIndex == 2)
    }
}
