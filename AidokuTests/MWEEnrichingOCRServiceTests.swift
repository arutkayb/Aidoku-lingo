//
//  MWEEnrichingOCRServiceTests.swift
//  AidokuTests
//
//  Swift Testing coverage for the OCR decorator that runs MWE detection.
//  Uses stubbed OCR + detector services; no Vision, no FoundationModels.
//

import Foundation
import CoreGraphics
import Testing
@testable import Aidoku

#if canImport(UIKit)
import UIKit

@Suite struct MWEEnrichingOCRServiceTests {

    // MARK: — Stub OCR service

    final class StubOCRService: OCRService, @unchecked Sendable {
        var nextResult: OCRResult
        var callCount = 0
        init(_ result: OCRResult) { self.nextResult = result }
        func recognize(image: UIImage, languages: [String]) async throws -> OCRResult {
            callCount += 1
            return nextResult
        }
    }

    // MARK: — Fixtures

    private func smallImage() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func makeWords(_ tokens: [(text: String, line: Int, rect: CGRect)]) -> [OCRWordBox] {
        tokens.map { OCRWordBox(text: $0.text, boundingBox: $0.rect, confidence: 1.0, lineIndex: $0.line) }
    }

    private func makeLines(_ items: [(text: String, rect: CGRect)]) -> [OCRLineBox] {
        items.map { OCRLineBox(text: $0.text, boundingBox: $0.rect, confidence: 1.0) }
    }

    /// 3 words on a single line, single bubble.
    private func singleBubbleResult() -> OCRResult {
        let lineRect = CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.05)
        let words = makeWords([
            (text: "kick", line: 0, rect: CGRect(x: 0.10, y: 0.50, width: 0.20, height: 0.05)),
            (text: "the", line: 0, rect: CGRect(x: 0.35, y: 0.50, width: 0.15, height: 0.05)),
            (text: "bucket", line: 0, rect: CGRect(x: 0.55, y: 0.50, width: 0.30, height: 0.05)),
        ])
        let lines = makeLines([(text: "kick the bucket", rect: lineRect)])
        return OCRResult(words: words, lines: lines)
    }

    // MARK: — Tests

    @Test func detection_disabled_returnsEmptyPhrases() async throws {
        let stub = StubOCRService(singleBubbleResult())
        let detector = StubMWEDetectionService()
        detector.nextResult = .success([
            DetectedPhraseSpan(text: "kick the bucket", kind: .idiom, bubbleIndex: 0, startWordIndex: 0, endWordIndex: 2, confidence: 1)
        ])
        let service = MWEEnrichingOCRService(
            underlying: stub,
            detector: detector,
            isEnabled: { false }
        )
        let result = try await service.recognize(image: smallImage(), languages: ["en-US"])
        #expect(result.phrases.isEmpty)
        #expect(detector.recordedCalls.isEmpty)
    }

    @Test func detector_throws_returnsEmptyPhrases() async throws {
        let stub = StubOCRService(singleBubbleResult())
        let detector = StubMWEDetectionService()
        struct DummyError: Error {}
        detector.nextResult = .failure(DummyError())
        let service = MWEEnrichingOCRService(
            underlying: stub,
            detector: detector,
            isEnabled: { true }
        )
        let result = try await service.recognize(image: smallImage(), languages: ["en-US"])
        #expect(result.phrases.isEmpty)
        #expect(result.words.count == 3)
    }

    @Test func validSpans_mappedToAbsoluteIndices() async throws {
        let stub = StubOCRService(singleBubbleResult())
        let detector = StubMWEDetectionService()
        detector.nextResult = .success([
            DetectedPhraseSpan(text: "kick the bucket", kind: .idiom, bubbleIndex: 0, startWordIndex: 0, endWordIndex: 2, confidence: 0.9)
        ])
        let service = MWEEnrichingOCRService(
            underlying: stub,
            detector: detector,
            isEnabled: { true }
        )
        let result = try await service.recognize(image: smallImage(), languages: ["en-US"])
        #expect(result.phrases.count == 1)
        let phrase = result.phrases[0]
        #expect(phrase.text == "kick the bucket")
        #expect(phrase.kind == .idiom)
        #expect(phrase.wordIndices == [0, 1, 2])
        #expect(phrase.lineIndices == [0])
    }

    @Test func unionBoundingBox_computedCorrectly() async throws {
        let stub = StubOCRService(singleBubbleResult())
        let detector = StubMWEDetectionService()
        detector.nextResult = .success([
            DetectedPhraseSpan(text: "kick the", kind: .compound, bubbleIndex: 0, startWordIndex: 0, endWordIndex: 1, confidence: 1)
        ])
        let service = MWEEnrichingOCRService(
            underlying: stub,
            detector: detector,
            isEnabled: { true }
        )
        let result = try await service.recognize(image: smallImage(), languages: ["en-US"])
        #expect(result.phrases.count == 1)
        // Union of (0.10,0.50,0.20,0.05) and (0.35,0.50,0.15,0.05) =
        // (0.10, 0.50, 0.40, 0.05).
        let box = result.phrases[0].boundingBox
        #expect(abs(box.minX - 0.10) < 0.0001)
        #expect(abs(box.minY - 0.50) < 0.0001)
        #expect(abs(box.maxX - 0.50) < 0.0001)
        #expect(abs(box.height - 0.05) < 0.0001)
    }

    @Test func outOfRangeSpan_isDropped() async throws {
        let stub = StubOCRService(singleBubbleResult())
        let detector = StubMWEDetectionService()
        // The decorator does not re-validate ranges (it relies on Task 2's
        // FoundationModelsMWEDetectionService.validate), but the absolute-index
        // mapping itself guards bubble/start/end bounds. Spans citing a bubble
        // that does not exist must NOT crash and must produce no phrases.
        detector.nextResult = .success([
            DetectedPhraseSpan(text: "x", kind: .idiom, bubbleIndex: 99, startWordIndex: 0, endWordIndex: 1, confidence: 1)
        ])
        let service = MWEEnrichingOCRService(
            underlying: stub,
            detector: detector,
            isEnabled: { true }
        )
        let result = try await service.recognize(image: smallImage(), languages: ["en-US"])
        #expect(result.phrases.isEmpty)
    }

    @Test func emptyWords_skipsDetector() async throws {
        let empty = OCRResult(words: [], lines: [])
        let stub = StubOCRService(empty)
        let detector = StubMWEDetectionService()
        let service = MWEEnrichingOCRService(
            underlying: stub,
            detector: detector,
            isEnabled: { true }
        )
        let result = try await service.recognize(image: smallImage(), languages: ["en-US"])
        #expect(result.phrases.isEmpty)
        #expect(detector.recordedCalls.isEmpty)
    }
}

@Suite struct BubbleGroupingTests {

    @Test func groupWordsByBubble_mapsWordsToCorrectBubble() {
        // Two bubbles: lines 0-1 (top) and line 2 (bottom, well below).
        let lines = [
            OCRLineBox(text: "Hello world", boundingBox: CGRect(x: 0.1, y: 0.9, width: 0.5, height: 0.05), confidence: 1),
            OCRLineBox(text: "you go", boundingBox: CGRect(x: 0.1, y: 0.83, width: 0.5, height: 0.05), confidence: 1),
            OCRLineBox(text: "Goodbye", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.05), confidence: 1),
        ]
        let words = [
            OCRWordBox(text: "Hello", boundingBox: .zero, confidence: 1, lineIndex: 0),
            OCRWordBox(text: "world", boundingBox: .zero, confidence: 1, lineIndex: 0),
            OCRWordBox(text: "you", boundingBox: .zero, confidence: 1, lineIndex: 1),
            OCRWordBox(text: "go", boundingBox: .zero, confidence: 1, lineIndex: 1),
            OCRWordBox(text: "Goodbye", boundingBox: .zero, confidence: 1, lineIndex: 2),
        ]
        let bubbles = BubbleGrouping.groupWordsByBubble(words: words, lines: lines)
        #expect(bubbles.count == 2)
        #expect(bubbles[0] == [0, 1, 2, 3])
        #expect(bubbles[1] == [4])
    }

    @Test func groupLinesIntoBubbles_emptyInputReturnsEmpty() {
        let result = BubbleGrouping.groupLinesIntoBubbles([])
        #expect(result.isEmpty)
    }
}

#endif // canImport(UIKit)
