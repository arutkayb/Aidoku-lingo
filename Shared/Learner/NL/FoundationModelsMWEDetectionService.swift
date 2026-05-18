//
//  FoundationModelsMWEDetectionService.swift
//  Aidoku
//
//  Concrete MWEDetectionService backed by Apple Foundation Models.
//  iOS 26+ only (deployment target enforces this).
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Foundation Models implementation of `MWEDetectionService`.
final class FoundationModelsMWEDetectionService: MWEDetectionService {

    /// Per-call closure runner. Production default opens a fresh `LanguageModelSession`
    /// and asks it to fill in an `MWEDetectionResult`. Tests inject a closure for
    /// deterministic behaviour without touching FoundationModels.
    typealias CallRunner = @Sendable (_ prompt: String) async throws -> [DetectedSpanItem]

    private let callRunner: CallRunner
    /// Single-call timeout in seconds before cancelling and retrying once.
    static let callTimeoutSeconds: Double = 12
    /// Maximum tokens in a valid phrase span.
    static let maxPhraseTokens = 6
    /// Minimum tokens in a valid phrase span (multi-word, by definition).
    static let minPhraseTokens = 2

    // MARK: — Generable raw output

    /// Stand-alone struct so the Generable type and the validation logic share a single
    /// shape regardless of whether FoundationModels is linked. Tests inject these directly.
    struct DetectedSpanItem: Sendable, Hashable {
        let text: String
        let kindRaw: String
        let bubbleIndex: Int
        let startWordIndex: Int
        let endWordIndex: Int
        var confidence: Float = 1.0
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    @Generable
    struct MWEDetectionResult {
        let spans: [GenerableSpan]
    }

    @available(iOS 26.0, *)
    @Generable
    struct GenerableSpan {
        let text: String
        /// One of: "compound", "idiom", "phrasalVerb", "namedEntity".
        let kind: String
        let bubbleIndex: Int
        let startWordIndex: Int
        let endWordIndex: Int
    }
    #endif

    // MARK: — Init

    init(callRunner: CallRunner? = nil) {
        if let callRunner {
            self.callRunner = callRunner
        } else {
            self.callRunner = Self.defaultCallRunner
        }
    }

    // MARK: — MWEDetectionService

    func detect(
        page: MWEDetectionPage,
        sourceLanguage: String
    ) async throws -> [DetectedPhraseSpan] {
        guard !page.bubbles.isEmpty else { return [] }

        let prompt = Self.buildPrompt(page: page, sourceLanguage: sourceLanguage)

        let rawItems: [DetectedSpanItem]
        do {
            rawItems = try await Self.runWithTimeoutAndRetry(
                seconds: Self.callTimeoutSeconds,
                runner: callRunner,
                prompt: prompt
            )
        } catch {
            print("[Learner] MWE detection timed out: \(error)")
            return []
        }

        let validated = Self.validate(rawItems, against: page)
        let resolved = Self.resolveOverlaps(validated)
        return resolved
    }

    // MARK: — Prompt

    static func buildPrompt(page: MWEDetectionPage, sourceLanguage: String) -> String {
        let languageName = languageName(for: sourceLanguage)
        var bubbleLines: [String] = []
        for (bIdx, bubble) in page.bubbles.enumerated() {
            let tokensPart = bubble.tokens.enumerated()
                .map { "\($0.offset):\($0.element)" }
                .joined(separator: " ")
            bubbleLines.append("Bubble \(bIdx): \(tokensPart)")
        }
        let bubblesBlock = bubbleLines.joined(separator: "\n")
        return """
        You are reading manga text in \(languageName). Each bubble below is one speech balloon. \
        Inside each bubble, every token has a local index. Identify multi-word expressions of \
        the following kinds: compound, idiom, phrasalVerb, namedEntity.

        Rules:
        - Spans MUST be 2 to \(maxPhraseTokens) tokens long.
        - Spans MUST NOT cross bubble boundaries.
        - Spans MUST NOT overlap each other.
        - kind MUST be one of: compound, idiom, phrasalVerb, namedEntity.
        - text MUST equal the original tokens joined by a single space, preserving case.

        Bubbles:
        \(bubblesBlock)
        """
    }

    static func languageName(for tag: String) -> String {
        let primary = String(tag.split(separator: "-").first ?? Substring(tag))
        let en = Locale(identifier: "en_US")
        if let name = en.localizedString(forLanguageCode: primary), !name.isEmpty {
            return name
        }
        return tag
    }

    // MARK: — Validation

    static func validate(
        _ items: [DetectedSpanItem],
        against page: MWEDetectionPage
    ) -> [DetectedPhraseSpan] {
        var out: [DetectedPhraseSpan] = []
        for item in items {
            guard item.bubbleIndex >= 0, item.bubbleIndex < page.bubbles.count else { continue }
            let bubble = page.bubbles[item.bubbleIndex]
            guard item.startWordIndex >= 0,
                  item.endWordIndex >= item.startWordIndex,
                  item.endWordIndex < bubble.tokens.count else { continue }
            let length = item.endWordIndex - item.startWordIndex + 1
            guard length >= minPhraseTokens, length <= maxPhraseTokens else { continue }
            guard let kind = PhraseKind(rawValue: item.kindRaw) else { continue }
            out.append(DetectedPhraseSpan(
                text: item.text,
                kind: kind,
                bubbleIndex: item.bubbleIndex,
                startWordIndex: item.startWordIndex,
                endWordIndex: item.endWordIndex,
                confidence: item.confidence
            ))
        }
        return out
    }

    // MARK: — Overlap resolution

    /// Of any set of spans sharing at least one `(bubbleIndex, wordIndex)` cell,
    /// only the longest survives; ties broken by smallest `(bubbleIndex, startWordIndex)`.
    static func resolveOverlaps(_ spans: [DetectedPhraseSpan]) -> [DetectedPhraseSpan] {
        guard spans.count > 1 else { return spans }
        // Sort by length DESC, then bubbleIndex ASC, then startWordIndex ASC.
        let sorted = spans.sorted { lhs, rhs in
            let lhsLen = lhs.endWordIndex - lhs.startWordIndex
            let rhsLen = rhs.endWordIndex - rhs.startWordIndex
            if lhsLen != rhsLen { return lhsLen > rhsLen }
            if lhs.bubbleIndex != rhs.bubbleIndex { return lhs.bubbleIndex < rhs.bubbleIndex }
            return lhs.startWordIndex < rhs.startWordIndex
        }
        var claimed: Set<Cell> = []
        var kept: [DetectedPhraseSpan] = []
        for span in sorted {
            let cells = Self.cells(for: span)
            if cells.contains(where: { claimed.contains($0) }) { continue }
            claimed.formUnion(cells)
            kept.append(span)
        }
        // Preserve a stable output ordering: by bubbleIndex, then startWordIndex.
        return kept.sorted { lhs, rhs in
            if lhs.bubbleIndex != rhs.bubbleIndex { return lhs.bubbleIndex < rhs.bubbleIndex }
            return lhs.startWordIndex < rhs.startWordIndex
        }
    }

    private struct Cell: Hashable { let bubble: Int; let word: Int }

    private static func cells(for span: DetectedPhraseSpan) -> [Cell] {
        (span.startWordIndex ... span.endWordIndex).map { Cell(bubble: span.bubbleIndex, word: $0) }
    }

    // MARK: — Timeout + retry

    static func runWithTimeoutAndRetry(
        seconds: Double,
        runner: @escaping CallRunner,
        prompt: String
    ) async throws -> [DetectedSpanItem] {
        do {
            return try await runWithTimeout(seconds: seconds, runner: runner, prompt: prompt)
        } catch {
            // One retry.
            return try await runWithTimeout(seconds: seconds, runner: runner, prompt: prompt)
        }
    }

    private static func runWithTimeout(
        seconds: Double,
        runner: @escaping CallRunner,
        prompt: String
    ) async throws -> [DetectedSpanItem] {
        try await withThrowingTaskGroup(of: [DetectedSpanItem].self) { group in
            group.addTask {
                try await runner(prompt)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw MWEDetectionError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: — Default production runner

    @Sendable
    static func defaultCallRunner(prompt: String) async throws -> [DetectedSpanItem] {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: MWEDetectionResult.self)
            return response.content.spans.map {
                DetectedSpanItem(
                    text: $0.text,
                    kindRaw: $0.kind,
                    bubbleIndex: $0.bubbleIndex,
                    startWordIndex: $0.startWordIndex,
                    endWordIndex: $0.endWordIndex,
                    confidence: 1.0
                )
            }
        } else {
            throw MWEDetectionError.unavailable
        }
        #else
        throw MWEDetectionError.unavailable
        #endif
    }
}
