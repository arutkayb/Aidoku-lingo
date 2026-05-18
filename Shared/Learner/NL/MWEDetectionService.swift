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
