//
//  CachingTranslationService.swift
//  Aidoku
//
//  In-memory LRU cache wrapper for any TranslationService.
//  Cache capacity: 500 entries (NSCache evicts under memory pressure automatically).
//  Cache keys: "\(method)|\(srcLang)|\(tgtLang)|\(input)".
//

import Foundation

/// NSCache requires reference-type values; box Sendable value types here.
private final class _CacheBox<T: Sendable>: NSObject, @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

final class CachingTranslationService: TranslationService {

    private let wrapped: any TranslationService
    private let cache = NSCache<NSString, AnyObject>()

    init(wrapping service: any TranslationService, countLimit: Int = 500) {
        self.wrapped = service
        cache.countLimit = countLimit
    }

    // MARK: — Cache helpers

    private func cacheKey(method: String, src: String, tgt: String, input: String) -> NSString {
        "\(method)|\(src)|\(tgt)|\(input)" as NSString
    }

    private func cached<T: Sendable>(key: NSString) -> T? {
        (cache.object(forKey: key) as? _CacheBox<T>)?.value
    }

    private func store<T: Sendable>(_ value: T, key: NSString) {
        cache.setObject(_CacheBox(value), forKey: key)
    }

    // MARK: — TranslationService

    func translateWord(
        _ word: String,
        sourceLanguage: String,
        targetLanguage: String
    ) async throws -> WordTranslation {
        let key = cacheKey(method: "word", src: sourceLanguage, tgt: targetLanguage, input: word)
        if let hit: WordTranslation = cached(key: key) { return hit }
        let result = try await wrapped.translateWord(word, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        store(result, key: key)
        return result
    }

    func translateSentence(
        _ sentence: String,
        sourceLanguage: String,
        targetLanguage: String
    ) async throws -> SentenceTranslation {
        let key = cacheKey(method: "sentence", src: sourceLanguage, tgt: targetLanguage, input: sentence)
        if let hit: SentenceTranslation = cached(key: key) { return hit }
        let result = try await wrapped.translateSentence(sentence, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
        store(result, key: key)
        return result
    }

    func simplifyToCEFR(
        _ sentence: String,
        level: CEFRLevel,
        language: String
    ) async throws -> String {
        let key = cacheKey(method: "simplify_\(level.rawValue)", src: language, tgt: "", input: sentence)
        if let hit: String = cached(key: key) { return hit }
        let result = try await wrapped.simplifyToCEFR(sentence, level: level, language: language)
        store(result, key: key)
        return result
    }

    func groupFragmentsIntoSentences(
        _ fragments: [TextFragment],
        language: String
    ) async throws -> [SentenceGroup] {
        let inputKey = fragments.map(\.text).joined(separator: "§")
        let key = cacheKey(method: "group", src: language, tgt: "", input: inputKey)
        if let hit: [SentenceGroup] = cached(key: key) { return hit }
        let result = try await wrapped.groupFragmentsIntoSentences(fragments, language: language)
        store(result, key: key)
        return result
    }

    /// Removes all cached translation results.
    func clearCache() {
        cache.removeAllObjects()
    }
}
