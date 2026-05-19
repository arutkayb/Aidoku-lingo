//
//  TranslationServiceFactory.swift
//  Aidoku
//

import Foundation

final class TranslationServiceFactory: @unchecked Sendable {
    static let shared: any TranslationService = CachingTranslationService(
        wrapping: FoundationModelsTranslationService()
    )

    static func clearCache() {
        (shared as? CachingTranslationService)?.clearCache()
    }
}
