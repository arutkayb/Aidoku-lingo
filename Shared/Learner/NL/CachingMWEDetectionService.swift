//
//  CachingMWEDetectionService.swift
//  Aidoku
//
//  NSCache-backed LRU wrapper around any MWEDetectionService.
//  Key = SHA1(canonical(pageText) + "|" + sourceLanguage).
//

import Foundation
import CryptoKit

final class CachingMWEDetectionService: MWEDetectionService {

    private let wrapped: any MWEDetectionService
    private let cache = NSCache<NSString, _SpanArrayBox>()

    init(wrapping service: any MWEDetectionService, countLimit: Int = 100) {
        self.wrapped = service
        cache.countLimit = countLimit
    }

    func detect(
        page: MWEDetectionPage,
        sourceLanguage: String
    ) async throws -> [DetectedPhraseSpan] {
        let key = Self.cacheKey(page: page, sourceLanguage: sourceLanguage)
        if let hit = cache.object(forKey: key)?.spans {
            return hit
        }
        let result = try await wrapped.detect(page: page, sourceLanguage: sourceLanguage)
        cache.setObject(_SpanArrayBox(result), forKey: key)
        return result
    }

    // MARK: — Cache key

    static func canonical(_ page: MWEDetectionPage) -> String {
        page.bubbles
            .map { $0.tokens.joined(separator: " ") }
            .joined(separator: "\n\n")
    }

    static func cacheKey(page: MWEDetectionPage, sourceLanguage: String) -> NSString {
        let canonical = canonical(page) + "|" + sourceLanguage
        let digest = Insecure.SHA1.hash(data: Data(canonical.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex as NSString
    }
}

/// NSCache requires reference-type values.
private final class _SpanArrayBox: NSObject, @unchecked Sendable {
    let spans: [DetectedPhraseSpan]
    init(_ spans: [DetectedPhraseSpan]) { self.spans = spans }
}
