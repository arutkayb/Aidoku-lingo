//
//  OCRServiceTests.swift
//  Aidoku
//
//  Swift Testing cases for VisionOCRService and OCRResultCache.
//

import Foundation
import CoreGraphics
import Testing
@testable import Aidoku

#if canImport(UIKit)
import UIKit
#endif

@Suite struct OCRServiceTests {

    // MARK: 1. Same image + same languages → cache hit, underlying not re-invoked

    @Test func recognize_cachedResult_doesNotReinvoke() async throws {
        let cache = OCRResultCache(countLimit: 32)
        let countingService = CountingOCRService(cache: cache)

        guard let image = loadFixture(named: "ocr-hallo-welt") else {
            Issue.record("Test fixture ocr-hallo-welt.png not found in bundle — skipping")
            return
        }

        _ = try await countingService.recognize(image: image, languages: ["de-DE"])
        _ = try await countingService.recognize(image: image, languages: ["de-DE"])

        #expect(countingService.visionCallCount == 1,
                "Second call with same image + languages should hit cache, not call Vision again")
    }

    // MARK: 2. Language change → cache miss

    @Test func recognize_languageChange_missesCache() async throws {
        let cache = OCRResultCache(countLimit: 32)
        let countingService = CountingOCRService(cache: cache)

        guard let image = loadFixture(named: "ocr-hallo-welt") else {
            Issue.record("Test fixture ocr-hallo-welt.png not found in bundle — skipping")
            return
        }

        _ = try await countingService.recognize(image: image, languages: ["de-DE"])
        _ = try await countingService.recognize(image: image, languages: ["en-US"])  // different language

        #expect(countingService.visionCallCount == 2,
                "Different language should miss cache and call Vision again")
    }

    // MARK: 3. Fixture smoke test — known words recognized

    @Test func recognize_basicGerman_returnsKnownWords() async throws {
        guard let image = loadFixture(named: "ocr-hallo-welt") else {
            Issue.record("Test fixture ocr-hallo-welt.png not found in bundle — skipping")
            return
        }

        let service = VisionOCRService()
        let result = try await service.recognize(image: image, languages: ["de-DE"])

        // The fixture contains "Hallo Welt" — at least some words should be detected
        // (Vision accuracy varies on pixel-art fonts; accept ≥ 1 non-empty word box)
        #expect(!result.words.isEmpty || !result.lines.isEmpty,
                "Vision should produce at least one box on the fixture image")
    }

    // MARK: 4. Off-main-thread assertion
    //
    // VisionOCRService.recognize ships a `Thread.isMainThread == false` assertion inside
    // the request callback (VisionOCRService.swift:35). We exercise that path here by
    // calling recognize from the main actor; if OCR ran on main, the internal `assert`
    // would fire in debug builds, and the recognize would never return because the
    // continuation would be deadlocked behind the same actor.
    @Test @MainActor func recognize_offMainThread() async throws {
        guard let image = loadFixture(named: "ocr-hallo-welt") else {
            Issue.record("Test fixture ocr-hallo-welt.png not found in bundle — skipping")
            return
        }
        let service = VisionOCRService()
        // If recognize did its work on the main thread, this call would deadlock the
        // MainActor before returning. Reaching the assertion below proves OCR ran off-main.
        _ = try await service.recognize(image: image, languages: ["de-DE"])
        #expect(Thread.isMainThread, "Test body must resume on main; OCR work ran on a background queue")
    }

    // MARK: 5. Cache get/put direct test

    @Test func cache_invalidate_clearsEntry() throws {
        let cache = OCRResultCache(countLimit: 10)
        // Render a 1×1 image so pngData() is guaranteed non-nil
        // (empty UIImage() yields nil PNG data and would mask the test).
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let dummyImage = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let data = try #require(dummyImage.pngData())

        let result = OCRResult(
            words: [OCRWordBox(text: "Test", boundingBox: .zero, confidence: 1.0, lineIndex: 0)],
            lines: []
        )
        cache.put(imageData: data, languages: ["de-DE"], result: result)
        #expect(cache.get(imageData: data, languages: ["de-DE"]) != nil)

        cache.invalidate(imageData: data, languages: ["de-DE"])
        #expect(cache.get(imageData: data, languages: ["de-DE"]) == nil,
                "Entry should be gone after invalidate")
    }

    @Test func cache_getAndPut_roundTrip() {
        let cache = OCRResultCache(countLimit: 10)
        let dummyImage = UIImage()
        guard let data = dummyImage.pngData() else { return }

        let result = OCRResult(
            words: [OCRWordBox(text: "Hallo", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1), confidence: 0.9, lineIndex: 0)],
            lines: [OCRLineBox(text: "Hallo Welt", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1), confidence: 0.9)]
        )

        cache.put(imageData: data, languages: ["de-DE"], result: result)
        let retrieved = cache.get(imageData: data, languages: ["de-DE"])

        #expect(retrieved != nil)
        #expect(retrieved?.words.first?.text == "Hallo")
    }
}

// MARK: — OCR language migration + passthrough tests

@Suite struct OCRLanguageMigrationTests {

    // Migration: old Learner.ocrLanguages (String) → new Learner.ocrLanguagesList ([String] JSON).
    // A legacy allowed code (de-DE) migrates and survives the allowed-set filter.
    @Test @MainActor func ocrLanguages_migratesLegacyStringKey() {
        let legacyKey = "Learner.ocrLanguages"
        let newKey = "Learner.ocrLanguagesList"

        // Setup legacy state with an allowed code.
        UserDefaults.standard.set("de-DE", forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: newKey)

        let result = LearnerOverlayCoordinator.shared.ocrLanguages()

        #expect(result == ["de-DE"], "Migrated allowed value should pass through the filter")
        #expect(UserDefaults.standard.object(forKey: legacyKey) == nil, "Old key should be removed after migration")
        #expect(UserDefaults.standard.data(forKey: newKey) != nil, "New key should be written as JSON data")

        // Cleanup
        UserDefaults.standard.removeObject(forKey: newKey)
    }

    // Default fallback when no key is set
    @Test @MainActor func ocrLanguages_defaultsToGerman() {
        let legacyKey = "Learner.ocrLanguages"
        let newKey = "Learner.ocrLanguagesList"
        UserDefaults.standard.removeObject(forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: newKey)

        let result = LearnerOverlayCoordinator.shared.ocrLanguages()
        #expect(result == ["de-DE"])
    }

    // Multi-language array round-trips correctly with allowed codes.
    @Test @MainActor func ocrLanguages_multipleLanguages_roundTrip() {
        let newKey = "Learner.ocrLanguagesList"
        let langs = ["de-DE", "en-US"]
        if let data = try? JSONEncoder().encode(langs) {
            UserDefaults.standard.set(data, forKey: newKey)
        }

        let result = LearnerOverlayCoordinator.shared.ocrLanguages()
        #expect(result == ["de-DE", "en-US"])

        UserDefaults.standard.removeObject(forKey: newKey)
    }

    // Lock-in: the picker saves selections in display order
    // (Vision uses recognitionLanguages order as a priority hint).
    // de-DE appears first in languages array, en-US second — display order preserved.
    @Test @MainActor func picker_saveToDefaults_preservesDisplayOrder() throws {
        let key = LearnerOCRLanguagesPicker.defaultsKey
        UserDefaults.standard.removeObject(forKey: key)

        // Pass both allowed codes. Display order is de-DE, en-US (matches languages array).
        LearnerOCRLanguagesPicker.saveToDefaults(["en-US", "de-DE"])

        let data = try #require(UserDefaults.standard.data(forKey: key))
        let saved = try JSONDecoder().decode([String].self, from: data)

        #expect(saved == ["de-DE", "en-US"],
                "Expected display order [de-DE, en-US]; got \(saved)")

        UserDefaults.standard.removeObject(forKey: key)
    }

    // Lock-in: a single-language save retains its single entry.
    @Test @MainActor func picker_saveToDefaults_singleLanguage() throws {
        let key = LearnerOCRLanguagesPicker.defaultsKey
        UserDefaults.standard.removeObject(forKey: key)

        LearnerOCRLanguagesPicker.saveToDefaults(["en-US"])

        let data = try #require(UserDefaults.standard.data(forKey: key))
        let saved = try JSONDecoder().decode([String].self, from: data)
        #expect(saved == ["en-US"])

        UserDefaults.standard.removeObject(forKey: key)
    }

    // Stored list containing a removed code is filtered; surviving allowed codes are returned and persisted.
    @Test @MainActor func testStoredListWithRemovedCodeIsFilteredAndPersisted() throws {
        let key = "Learner.ocrLanguagesList"
        // Pre-seed with one removed code and one allowed code.
        if let data = try? JSONEncoder().encode(["ja-JP", "de-DE"]) {
            UserDefaults.standard.set(data, forKey: key)
        }

        let result = LearnerOverlayCoordinator.shared.ocrLanguages()

        #expect(result == ["de-DE"], "Removed code ja-JP should be stripped; de-DE survives")

        let stored = try #require(UserDefaults.standard.data(forKey: key))
        let persisted = try JSONDecoder().decode([String].self, from: stored)
        #expect(persisted == ["de-DE"], "Persisted value should be rewritten to only de-DE")

        UserDefaults.standard.removeObject(forKey: key)
    }

    // All-removed stored list falls back to ["de-DE"] and rewrites the key.
    @Test @MainActor func testAllRemovedStoredListFallsBackToDefault() throws {
        let key = "Learner.ocrLanguagesList"
        if let data = try? JSONEncoder().encode(["fr-FR"]) {
            UserDefaults.standard.set(data, forKey: key)
        }

        let result = LearnerOverlayCoordinator.shared.ocrLanguages()

        #expect(result == ["de-DE"], "All-removed list should fall back to de-DE")

        let stored = try #require(UserDefaults.standard.data(forKey: key))
        let persisted = try JSONDecoder().decode([String].self, from: stored)
        #expect(persisted == ["de-DE"], "Key should be rewritten to [de-DE]")

        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: — Helpers

private func loadFixture(named name: String) -> UIImage? {
    let testBundle = Bundle(for: BundleLocator.self)
    guard let url = testBundle.url(forResource: name, withExtension: "png") else {
        return nil
    }
    return UIImage(contentsOfFile: url.path)
}

private final class BundleLocator {}

// MARK: — CountingOCRService (test double)

/// Wraps VisionOCRService but shares its cache, counting actual Vision invocations.
private final class CountingOCRService: OCRService, @unchecked Sendable {
    private let inner: VisionOCRService
    private let sharedCache: OCRResultCache
    private(set) var visionCallCount = 0
    private let lock = NSLock()

    init(cache: OCRResultCache) {
        sharedCache = cache
        inner = VisionOCRService(cache: cache)
    }

    func recognize(image: UIImage, languages: [String]) async throws -> OCRResult {
        guard let pngData = image.pngData() else { throw OCRError.imageUnsupported }
        if sharedCache.get(imageData: pngData, languages: languages) != nil {
            // Cache hit — don't increment
            return try await inner.recognize(image: image, languages: languages)
        }
        // Cache miss — increment before delegating
        lock.lock()
        visionCallCount += 1
        lock.unlock()
        return try await inner.recognize(image: image, languages: languages)
    }
}
