//
//  TranslationService.swift
//  Aidoku
//
//  Protocol and shared types for the translation service layer.
//  All types are Sendable so they cross actor boundaries safely.
//

import Foundation

// MARK: — Supporting types

/// CEFR proficiency level used for simplification requests.
public enum CEFRLevel: String, Sendable, CaseIterable {
    case a1 = "A1"
    case a2 = "A2"
    case b1 = "B1"
    case b2 = "B2"
    case c1 = "C1"
    case c2 = "C2"
}

/// A single detected text fragment on a manga page (from OCR).
public struct TextFragment: Sendable, Hashable {
    public let text: String
    /// Index of this fragment in the original page-level fragment list.
    public let index: Int

    public init(text: String, index: Int) {
        self.text = text
        self.index = index
    }
}

/// The result of a word-level translation request.
public struct WordTranslation: Sendable, Hashable {
    public let lemma: String
    public let translation: String
    public let partOfSpeech: String?
    public let exampleSentence: String?

    public init(lemma: String, translation: String, partOfSpeech: String? = nil, exampleSentence: String? = nil) {
        self.lemma = lemma
        self.translation = translation
        self.partOfSpeech = partOfSpeech
        self.exampleSentence = exampleSentence
    }
}

/// The result of a sentence-level translation request.
public struct SentenceTranslation: Sendable, Hashable {
    public let original: String
    public let translation: String

    public init(original: String, translation: String) {
        self.original = original
        self.translation = translation
    }
}

/// A group of fragments that together form one sentence.
public struct SentenceGroup: Sendable, Hashable {
    /// Indices into the original fragment list.
    public let fragmentIndices: [Int]
    /// Fragments joined with spaces (lightly cleaned).
    public let combinedText: String

    public init(fragmentIndices: [Int], combinedText: String) {
        self.fragmentIndices = fragmentIndices
        self.combinedText = combinedText
    }
}

// MARK: — Error

/// Errors surfaced through the translation service stack.
/// All user-visible cases are mapped to `LEARNER_TRANSLATION_*` localized strings at the call site.
public enum TranslationError: Error, Sendable {
    /// Apple Foundation Models unavailable (iOS < 26 or not downloaded yet).
    case unavailable
    /// This provider does not support this method.
    case notSupportedByProvider
    /// Network-level failure — see `underlying` for the raw error.
    case networkError(underlying: Error)
    /// The provider returned a response we couldn't parse.
    case unexpectedResponse(String)
}

// MARK: — Protocol

/// The single interface for all translation operations.
/// Implementations include `FoundationModelsTranslationService` and `CachingTranslationService`.
public protocol TranslationService: Sendable {

    /// Translate a single word or lemma.
    func translateWord(
        _ word: String,
        sourceLanguage: String,
        targetLanguage: String
    ) async throws -> WordTranslation

    /// Translate a full sentence.
    func translateSentence(
        _ sentence: String,
        sourceLanguage: String,
        targetLanguage: String
    ) async throws -> SentenceTranslation

    /// Rephrase a sentence at the given CEFR level (same language).
    func simplifyToCEFR(
        _ sentence: String,
        level: CEFRLevel,
        language: String
    ) async throws -> String

    /// Group OCR-detected text fragments into sentence clusters.
    func groupFragmentsIntoSentences(
        _ fragments: [TextFragment],
        language: String
    ) async throws -> [SentenceGroup]
}
