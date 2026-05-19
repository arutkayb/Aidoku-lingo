//
//  HeuristicMWEDetectionService.swift
//  Aidoku
//
//  Foundation Models–free MWE detection backed by curated dictionaries and
//  NaturalLanguage lemmatization. Used as the fallback when Apple Intelligence
//  is unavailable (older devices, AI disabled, model assets missing).
//

import Foundation
import NaturalLanguage

final class HeuristicMWEDetectionService: MWEDetectionService {

    /// Largest phrase the detector emits. Mirrors the FM service so cache keys
    /// and overlap-resolution behaviour stay consistent across backends.
    static let maxPhraseTokens = 6
    static let minPhraseTokens = 2

    /// Confidence assigned to heuristic matches. Lower than the FM 1.0 default
    /// so a future merging composite (vs. the current first-non-empty wins one)
    /// would prefer FM spans on conflict.
    static let dictionaryConfidence: Float = 0.6
    static let namedEntityConfidence: Float = 0.5

    func detect(
        page: MWEDetectionPage,
        sourceLanguage: String
    ) async throws -> [DetectedPhraseSpan] {
        guard !page.bubbles.isEmpty else { return [] }
        let entries = IdiomDictionary.entries(for: sourceLanguage)
        if entries.isEmpty { return [] }

        var spans: [DetectedPhraseSpan] = []
        for (bubbleIdx, bubble) in page.bubbles.enumerated() {
            guard bubble.tokens.count >= Self.minPhraseTokens else { continue }
            spans.append(contentsOf: Self.detectDictionary(
                bubbleIdx: bubbleIdx,
                tokens: bubble.tokens,
                entries: entries,
                languageTag: sourceLanguage
            ))
            spans.append(contentsOf: Self.detectNamedEntities(
                bubbleIdx: bubbleIdx,
                tokens: bubble.tokens,
                languageTag: sourceLanguage
            ))
        }
        return DetectedPhraseSpan.resolveOverlaps(spans)
    }

    // MARK: — Dictionary matching

    static func detectDictionary(
        bubbleIdx: Int,
        tokens: [String],
        entries: [IdiomEntry],
        languageTag: String
    ) -> [DetectedPhraseSpan] {
        let lemmas = NLTaggerLemmatizer.lemmas(for: tokens, languageTag: languageTag)
        let lowered = tokens.map { $0.lowercased() }

        var spans: [DetectedPhraseSpan] = []
        for entry in entries {
            let n = entry.lemmas.count
            guard n >= Self.minPhraseTokens, n <= Self.maxPhraseTokens, n <= tokens.count else { continue }
            let upperBound = tokens.count - n
            if upperBound < 0 { continue }
            for start in 0 ... upperBound {
                var matched = true
                for offset in 0 ..< n {
                    let pattern = entry.lemmas[offset]
                    let surface = lowered[start + offset]
                    let lemma = lemmas[start + offset]
                    if !tokenMatches(pattern: pattern, surface: surface, lemma: lemma, stemTolerant: entry.stemTolerant) {
                        matched = false
                        break
                    }
                }
                guard matched else { continue }
                let endIdx = start + n - 1
                let text = tokens[start ... endIdx].joined(separator: " ")
                spans.append(DetectedPhraseSpan(
                    text: text,
                    kind: entry.kind,
                    bubbleIndex: bubbleIdx,
                    startWordIndex: start,
                    endWordIndex: endIdx,
                    confidence: Self.dictionaryConfidence
                ))
            }
        }
        return spans
    }

    /// Token-pattern match. Exact lemma equality OR exact surface equality
    /// always wins. When `stemTolerant` is true (Turkish), the pattern is also
    /// accepted as a prefix of the surface or lemma, provided the pattern is
    /// long enough to keep false-positive risk low.
    static func tokenMatches(
        pattern: String,
        surface: String,
        lemma: String,
        stemTolerant: Bool
    ) -> Bool {
        if pattern == surface { return true }
        if pattern == lemma { return true }
        if stemTolerant && pattern.count >= 3 {
            return surface.hasPrefix(pattern) || lemma.hasPrefix(pattern)
        }
        return false
    }

    // MARK: — Named-entity matching

    /// Walks the per-token name tags and emits one `namedEntity` span per run
    /// of contiguous tokens carrying the same name tag. Single-token names are
    /// dropped (the MWE protocol requires ≥ 2 tokens).
    static func detectNamedEntities(
        bubbleIdx: Int,
        tokens: [String],
        languageTag: String
    ) -> [DetectedPhraseSpan] {
        let tags = NLTaggerLemmatizer.nameTags(for: tokens, languageTag: languageTag)
        var spans: [DetectedPhraseSpan] = []
        var runStart: Int?
        var runTag: NLTag?

        func flush(end: Int) {
            guard let start = runStart else { return }
            let length = end - start + 1
            if length >= Self.minPhraseTokens && length <= Self.maxPhraseTokens {
                let text = tokens[start ... end].joined(separator: " ")
                spans.append(DetectedPhraseSpan(
                    text: text,
                    kind: .namedEntity,
                    bubbleIndex: bubbleIdx,
                    startWordIndex: start,
                    endWordIndex: end,
                    confidence: Self.namedEntityConfidence
                ))
            }
            runStart = nil
            runTag = nil
        }

        for (index, tag) in tags.enumerated() {
            if tag != nil && tag == runTag { continue }
            if runStart != nil { flush(end: index - 1) }
            if tag != nil {
                runStart = index
                runTag = tag
            }
        }
        if runStart != nil { flush(end: tokens.count - 1) }
        return spans
    }
}
