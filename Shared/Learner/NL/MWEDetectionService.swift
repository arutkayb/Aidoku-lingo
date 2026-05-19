//
//  MWEDetectionService.swift
//  Aidoku
//
//  Protocol and value types for multi-word-expression detection on a manga page.
//  All types are Sendable so they cross actor boundaries safely.
//

import Foundation

// MARK: — PhraseKind

/// The semantic category assigned to a detected multi-word expression.
/// Stored as a `String` raw value so Core Data can persist `kind = phrase.kind.rawValue`.
public enum PhraseKind: String, Codable, Sendable, Hashable {
    case compound
    case idiom
    case phrasalVerb
    case namedEntity

    /// Localized display name for chip rendering in `WordLookupSheet`.
    public var displayName: String {
        switch self {
        case .compound:    return NSLocalizedString("LEARNER_PHRASE_KIND_COMPOUND", comment: "")
        case .idiom:       return NSLocalizedString("LEARNER_PHRASE_KIND_IDIOM", comment: "")
        case .phrasalVerb: return NSLocalizedString("LEARNER_PHRASE_KIND_PHRASAL_VERB", comment: "")
        case .namedEntity: return NSLocalizedString("LEARNER_PHRASE_KIND_NAMED_ENTITY", comment: "")
        }
    }
}

// MARK: — Input types

/// One OCR bubble's tokens (the contents of a single speech balloon, in reading order).
public struct MWEDetectionBubble: Sendable, Hashable {
    public let tokens: [String]

    public init(tokens: [String]) {
        self.tokens = tokens
    }
}

/// The page-level input handed to the detector.
public struct MWEDetectionPage: Sendable, Hashable {
    public let bubbles: [MWEDetectionBubble]

    public init(bubbles: [MWEDetectionBubble]) {
        self.bubbles = bubbles
    }
}

// MARK: — Output type

/// One validated, non-overlapping phrase span returned by the detector.
/// Indices reference `MWEDetectionPage.bubbles[bubbleIndex].tokens[startWordIndex...endWordIndex]`.
public struct DetectedPhraseSpan: Sendable, Hashable {
    public let text: String
    public let kind: PhraseKind
    public let bubbleIndex: Int
    public let startWordIndex: Int
    public let endWordIndex: Int
    public let confidence: Float

    public init(
        text: String,
        kind: PhraseKind,
        bubbleIndex: Int,
        startWordIndex: Int,
        endWordIndex: Int,
        confidence: Float
    ) {
        self.text = text
        self.kind = kind
        self.bubbleIndex = bubbleIndex
        self.startWordIndex = startWordIndex
        self.endWordIndex = endWordIndex
        self.confidence = confidence
    }
}

// MARK: — Error

public enum MWEDetectionError: Error, Sendable {
    case unavailable
    case timedOut
    case underlying(Error)
}

// MARK: — Protocol

/// Detects multi-word expressions on a single OCR page.
public protocol MWEDetectionService: Sendable {
    func detect(page: MWEDetectionPage, sourceLanguage: String) async throws -> [DetectedPhraseSpan]
}

// MARK: — Overlap resolution

extension DetectedPhraseSpan {
    /// Of any set of spans sharing at least one `(bubbleIndex, wordIndex)` cell,
    /// only the longest survives; ties broken by smallest `(bubbleIndex, startWordIndex)`.
    /// Output is sorted by `(bubbleIndex, startWordIndex)` for stable downstream use.
    public static func resolveOverlaps(_ spans: [DetectedPhraseSpan]) -> [DetectedPhraseSpan] {
        guard spans.count > 1 else { return spans }
        let sorted = spans.sorted { lhs, rhs in
            let lhsLen = lhs.endWordIndex - lhs.startWordIndex
            let rhsLen = rhs.endWordIndex - rhs.startWordIndex
            if lhsLen != rhsLen { return lhsLen > rhsLen }
            if lhs.bubbleIndex != rhs.bubbleIndex { return lhs.bubbleIndex < rhs.bubbleIndex }
            return lhs.startWordIndex < rhs.startWordIndex
        }
        struct Cell: Hashable { let bubble: Int; let word: Int }
        var claimed: Set<Cell> = []
        var kept: [DetectedPhraseSpan] = []
        for span in sorted {
            let cells = (span.startWordIndex ... span.endWordIndex)
                .map { Cell(bubble: span.bubbleIndex, word: $0) }
            if cells.contains(where: { claimed.contains($0) }) { continue }
            claimed.formUnion(cells)
            kept.append(span)
        }
        return kept.sorted { lhs, rhs in
            if lhs.bubbleIndex != rhs.bubbleIndex { return lhs.bubbleIndex < rhs.bubbleIndex }
            return lhs.startWordIndex < rhs.startWordIndex
        }
    }
}
