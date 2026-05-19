//
//  MWEEnrichingOCRService.swift
//  Aidoku
//
//  Decorator that runs the underlying OCR service, then asks a MWEDetectionService
//  to identify multi-word expressions in the recognised text. The result is a fresh
//  OCRResult with the same words/lines and a populated `phrases` field.
//

#if canImport(UIKit)
import Foundation
import CoreGraphics
import UIKit

final class MWEEnrichingOCRService: OCRService {

    private let underlying: any OCRService
    private let detector: any MWEDetectionService
    private let isEnabled: @Sendable () -> Bool

    init(
        underlying: any OCRService,
        detector: any MWEDetectionService,
        isEnabled: @escaping @Sendable () -> Bool
    ) {
        self.underlying = underlying
        self.detector = detector
        self.isEnabled = isEnabled
    }

    // MARK: — OCRService

    func recognize(image: UIImage, languages: [String]) async throws -> OCRResult {
        let base = try await underlying.recognize(image: image, languages: languages)
        let enabled = isEnabled()
        guard enabled, !base.words.isEmpty else {
            print("[Learner MWE] skip enabled=\(enabled) words=\(base.words.count)")
            return base
        }

        let bubbles = BubbleGrouping.groupWordsByBubble(words: base.words, lines: base.lines)
        guard !bubbles.isEmpty else {
            print("[Learner MWE] skip bubbles=0 words=\(base.words.count)")
            return base
        }

        // Build detector input (per-bubble token lists local to each bubble).
        let detectionBubbles = bubbles.map { wordIndices in
            MWEDetectionBubble(tokens: wordIndices.map { base.words[$0].text })
        }
        let page = MWEDetectionPage(bubbles: detectionBubbles)
        let sourceLanguage = languages.first ?? "en-US"

        let spans: [DetectedPhraseSpan]
        do {
            spans = try await detector.detect(page: page, sourceLanguage: sourceLanguage)
        } catch {
            print("[Learner MWE] detection failed lang=\(sourceLanguage) error=\(error)")
            return base
        }

        let phrases = spans.compactMap { span -> OCRPhrase? in
            Self.mapSpanToPhrase(span, bubbleWordIndices: bubbles, words: base.words)
        }
        print("[Learner MWE] lang=\(sourceLanguage) bubbles=\(bubbles.count) spans=\(spans.count) phrases=\(phrases.count)")
        return OCRResult(words: base.words, lines: base.lines, phrases: phrases)
    }

    // MARK: — Mapping

    /// Resolves a detector span (with bubble-local token indices) into absolute
    /// `OCRResult.words` indices. Returns nil if any index is out of range — guards
    /// against detector output that survived validation but doesn't match the
    /// concrete bubble structure (e.g. mismatched bubble counts).
    static func mapSpanToPhrase(
        _ span: DetectedPhraseSpan,
        bubbleWordIndices: [[Int]],
        words: [OCRWordBox]
    ) -> OCRPhrase? {
        guard span.bubbleIndex >= 0, span.bubbleIndex < bubbleWordIndices.count else { return nil }
        let wordList = bubbleWordIndices[span.bubbleIndex]
        guard span.startWordIndex >= 0,
              span.endWordIndex >= span.startWordIndex,
              span.endWordIndex < wordList.count else { return nil }

        let absoluteIndices = Array(wordList[span.startWordIndex ... span.endWordIndex])
        let lineIndices = Array(Set(absoluteIndices.map { words[$0].lineIndex })).sorted()
        let boxes = absoluteIndices.map { words[$0].boundingBox }
        let union = unionRect(boxes)
        return OCRPhrase(
            text: span.text,
            kind: span.kind,
            wordIndices: absoluteIndices,
            lineIndices: lineIndices,
            boundingBox: union,
            confidence: span.confidence
        )
    }

    private static func unionRect(_ rects: [CGRect]) -> CGRect {
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }
}
#endif // canImport(UIKit)
