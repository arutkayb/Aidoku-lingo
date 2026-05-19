//
//  NLTaggerLemmatizer.swift
//  Aidoku
//
//  Thin wrapper around Apple's NaturalLanguage framework. Lemmatizes a sequence
//  of pre-tokenized surface forms in a given source language.
//
//  Used by HeuristicMWEDetectionService — Foundation Models–free phrase detection
//  for devices without Apple Intelligence.
//

import Foundation
import NaturalLanguage

enum NLTaggerLemmatizer {

    /// Lemmatizes each surface token. Returns an array of the same length as the input;
    /// when the tagger can't produce a lemma for a token (common for short particles,
    /// proper nouns, or words it doesn't recognize), the lowercased original surface
    /// form fills the slot so callers can still compare against it as a fallback.
    static func lemmas(for tokens: [String], languageTag: String) -> [String] {
        guard !tokens.isEmpty else { return [] }
        let language = NLLanguage.from(languageTag: languageTag)
        let tagger = NLTagger(tagSchemes: [.lemma])
        // Join with single spaces — preserves the 1:1 token-index mapping the loop relies on
        // because we walk the joined string and slice into the same token boundaries.
        let joined = tokens.joined(separator: " ")
        tagger.string = joined
        tagger.setLanguage(language, range: joined.startIndex ..< joined.endIndex)

        var output = tokens.map { $0.lowercased() }
        var tokenIndex = 0
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

        tagger.enumerateTags(
            in: joined.startIndex ..< joined.endIndex,
            unit: .word,
            scheme: .lemma,
            options: options
        ) { tag, range in
            guard tokenIndex < output.count else { return false }
            let surface = String(joined[range])
            // Skip whitespace-only tokens or empty ranges.
            if surface.isEmpty { return true }
            if let tag, !tag.rawValue.isEmpty {
                output[tokenIndex] = tag.rawValue.lowercased()
            }
            tokenIndex += 1
            return true
        }
        return output
    }

    /// Returns NaturalLanguage's per-token name tags (personalName / placeName /
    /// organizationName). Used by the heuristic detector to surface multi-token
    /// named entities as `PhraseKind.namedEntity` spans.
    static func nameTags(for tokens: [String], languageTag: String) -> [NLTag?] {
        guard !tokens.isEmpty else { return [] }
        let language = NLLanguage.from(languageTag: languageTag)
        let tagger = NLTagger(tagSchemes: [.nameType])
        let joined = tokens.joined(separator: " ")
        tagger.string = joined
        tagger.setLanguage(language, range: joined.startIndex ..< joined.endIndex)

        var output: [NLTag?] = Array(repeating: nil, count: tokens.count)
        var tokenIndex = 0
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]

        tagger.enumerateTags(
            in: joined.startIndex ..< joined.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            guard tokenIndex < output.count else { return false }
            let surface = String(joined[range])
            if surface.isEmpty { return true }
            if let tag,
               tag == .personalName || tag == .placeName || tag == .organizationName {
                output[tokenIndex] = tag
            }
            tokenIndex += 1
            return true
        }
        return output
    }
}

private extension NLLanguage {
    /// Maps a BCP-47 tag (e.g. "tr-TR") to NLLanguage. Unknown tags fall back to
    /// `.undetermined` so NLTagger will auto-detect or skip lemmatization.
    static func from(languageTag: String) -> NLLanguage {
        let primary = String(languageTag.split(separator: "-").first ?? Substring(languageTag)).lowercased()
        switch primary {
        case "en": return .english
        case "de": return .german
        case "tr": return .turkish
        case "fr": return .french
        case "es": return .spanish
        case "it": return .italian
        case "pt": return .portuguese
        case "ja": return .japanese
        case "zh": return .simplifiedChinese
        case "ko": return .korean
        default:   return .undetermined
        }
    }
}
