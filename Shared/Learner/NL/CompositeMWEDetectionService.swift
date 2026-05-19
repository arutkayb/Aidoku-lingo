//
//  CompositeMWEDetectionService.swift
//  Aidoku
//
//  Chains a primary detector (Foundation Models on Apple-Intelligence-eligible
//  hardware) with a fallback (heuristic dictionary + NaturalLanguage). The
//  fallback runs only when the primary returns an empty result or throws —
//  cheap on the AI-eligible happy path, useful everywhere else.
//

import Foundation

final class CompositeMWEDetectionService: MWEDetectionService {

    private let primary: any MWEDetectionService
    private let fallback: any MWEDetectionService

    init(primary: any MWEDetectionService, fallback: any MWEDetectionService) {
        self.primary = primary
        self.fallback = fallback
    }

    func detect(
        page: MWEDetectionPage,
        sourceLanguage: String
    ) async throws -> [DetectedPhraseSpan] {
        let primaryResult: [DetectedPhraseSpan]
        do {
            primaryResult = try await primary.detect(page: page, sourceLanguage: sourceLanguage)
        } catch {
            return (try? await fallback.detect(page: page, sourceLanguage: sourceLanguage)) ?? []
        }
        if !primaryResult.isEmpty {
            return primaryResult
        }
        return (try? await fallback.detect(page: page, sourceLanguage: sourceLanguage)) ?? []
    }
}
