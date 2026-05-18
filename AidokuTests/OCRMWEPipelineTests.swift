//
//  OCRMWEPipelineTests.swift
//  AidokuTests
//
//  End-to-end stubbed pipeline tests covering the `Learner.detectPhrases`
//  UserDefaults toggle plus the phrase → vocab persistence path.
//

import Foundation
import CoreData
import CoreGraphics
import Testing
@testable import Aidoku

#if canImport(UIKit)
import UIKit

@Suite struct OCRMWEPipelineTests {

    // MARK: — Stub OCR

    final class StubOCRService: OCRService, @unchecked Sendable {
        var nextResult: OCRResult
        init(_ result: OCRResult) { self.nextResult = result }
        func recognize(image: UIImage, languages: [String]) async throws -> OCRResult {
            nextResult
        }
    }

    // MARK: — Fixtures

    private func image() -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
    }

    private func phraseResult() -> OCRResult {
        let lineRect = CGRect(x: 0.1, y: 0.5, width: 0.8, height: 0.05)
        let words = [
            OCRWordBox(text: "kick", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.05), confidence: 1, lineIndex: 0),
            OCRWordBox(text: "the", boundingBox: CGRect(x: 0.35, y: 0.5, width: 0.15, height: 0.05), confidence: 1, lineIndex: 0),
            OCRWordBox(text: "bucket", boundingBox: CGRect(x: 0.55, y: 0.5, width: 0.3, height: 0.05), confidence: 1, lineIndex: 0)
        ]
        let lines = [OCRLineBox(text: "kick the bucket", boundingBox: lineRect, confidence: 1)]
        return OCRResult(words: words, lines: lines)
    }

    private func detectorReturning(_ kind: PhraseKind = .idiom) -> StubMWEDetectionService {
        let detector = StubMWEDetectionService()
        detector.nextResult = .success([
            DetectedPhraseSpan(
                text: "kick the bucket",
                kind: kind,
                bubbleIndex: 0,
                startWordIndex: 0,
                endWordIndex: 2,
                confidence: 0.95
            )
        ])
        return detector
    }

    // MARK: — Tests

    /// Toggle OFF (UserDefaults bool false) suppresses detector and returns no phrases.
    @Test func toggleOff_skipsDetection() async throws {
        UserDefaults.standard.set(false, forKey: "Learner.detectPhrases")
        defer { UserDefaults.standard.removeObject(forKey: "Learner.detectPhrases") }

        let stub = StubOCRService(phraseResult())
        let detector = detectorReturning()
        let service = MWEEnrichingOCRService(
            underlying: stub,
            detector: detector,
            isEnabled: {
                UserDefaults.standard.object(forKey: "Learner.detectPhrases") as? Bool ?? true
            }
        )
        let result = try await service.recognize(image: image(), languages: ["en-US"])
        #expect(result.phrases.isEmpty)
        #expect(detector.recordedCalls.isEmpty)
    }

    /// Toggle ON (default; absent key) runs the detector and surfaces phrases.
    @Test func toggleOn_runsDetection() async throws {
        UserDefaults.standard.removeObject(forKey: "Learner.detectPhrases")

        let stub = StubOCRService(phraseResult())
        let detector = detectorReturning()
        let service = MWEEnrichingOCRService(
            underlying: stub,
            detector: detector,
            isEnabled: {
                UserDefaults.standard.object(forKey: "Learner.detectPhrases") as? Bool ?? true
            }
        )
        let result = try await service.recognize(image: image(), languages: ["en-US"])
        #expect(result.phrases.count == 1)
        #expect(result.phrases.first?.text == "kick the bucket")
        #expect(detector.recordedCalls.count == 1)
    }

    /// End-to-end: a detected phrase from the pipeline can be persisted as a vocab
    /// entry with its `kind` written through `upsertVocabularyEntry(... kind:)`.
    @Test func endToEnd_phrasePipeline_persistsKindOnUpsert() async throws {
        UserDefaults.standard.removeObject(forKey: "Learner.detectPhrases")

        let container = makeInMemoryContainer()
        let ctx = container.viewContext
        let stub = StubOCRService(phraseResult())
        let detector = detectorReturning(.idiom)
        let service = MWEEnrichingOCRService(
            underlying: stub,
            detector: detector,
            isEnabled: { true }
        )

        let result = try await service.recognize(image: image(), languages: ["en-US"])
        let phrase = try #require(result.phrases.first)

        let entry = CoreDataManager.shared.upsertVocabularyEntry(
            language: "en-US",
            lemma: phrase.text,
            surfaceForm: phrase.text,
            translation: nil,
            sourceMangaId: nil,
            sourceMangaSourceId: nil,
            kind: phrase.kind.rawValue,
            context: ctx
        )

        #expect(entry.kind == "idiom")
        #expect(entry.isPhrase == true)
        let refetched = CoreDataManager.shared.getVocabularyEntry(language: "en-US", lemma: "kick the bucket", context: ctx)
        #expect(refetched?.kind == "idiom")
    }
}

#endif // canImport(UIKit)
