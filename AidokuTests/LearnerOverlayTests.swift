//
//  LearnerOverlayTests.swift
//  Aidoku
//
//  Swift Testing cases for Task 5: LearnerOverlayCoordinator, LearnerOverlayView, VocabIndex.
//

import Foundation
import Combine
import UIKit
import Testing
@testable import Aidoku

// MARK: — LearnerOverlayView layout tests

@Suite struct LearnerOverlayViewTests {

    // Helpers

    private func makeWords(_ count: Int) -> [OCRWordBox] {
        (0..<count).map { i in
            OCRWordBox(
                text: "Word\(i)",
                boundingBox: CGRect(x: 0.1 * Double(i), y: 0.1, width: 0.08, height: 0.05),
                confidence: 0.95,
                lineIndex: 0
            )
        }
    }

    private func makeContext() -> LearnerPageContext {
        LearnerPageContext(sourceId: "src", mangaId: "manga1", chapterId: "ch1", pageIndex: 0)
    }

    // Test 1: correct number of word region controls are created
    @Test @MainActor func update_createsCorrectNumberOfRegions() {
        let view = LearnerOverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let words = makeWords(3)
        let vocab = VocabIndex.shared

        view.update(words: words, vocabIndex: vocab, language: "de-DE", pageContext: makeContext())

        // All 3 words should produce subview controls
        #expect(view.subviews.count == 3)
    }

    // Test 2: clear removes all subviews
    @Test @MainActor func clear_removesAllSubviews() {
        let view = LearnerOverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let words = makeWords(5)

        view.update(words: words, vocabIndex: VocabIndex.shared, language: "de-DE", pageContext: makeContext())
        #expect(view.subviews.count == 5)

        view.clear()
        #expect(view.subviews.isEmpty)
    }

    // Test 3: empty-space taps are claimed by the overlay so its long-press recognizer fires.
    // Word-region touches are still routed to their UIControl subviews.
    @Test @MainActor func hitTest_emptySpace_returnsSelf() {
        let view = LearnerOverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let hit = view.hitTest(CGPoint(x: 200, y: 300), with: nil)
        #expect(hit === view, "Overlay must claim empty-space touches so long-press can fire")
    }

    // Test 3b: with words present, hit on a word region resolves to the WordRegionControl subview.
    @Test @MainActor func hitTest_wordRegion_returnsControl() {
        let view = LearnerOverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        // One large word spanning the full overlay
        let word = OCRWordBox(
            text: "Wort",
            boundingBox: CGRect(x: 0, y: 0, width: 1.0, height: 1.0),
            confidence: 0.9,
            lineIndex: 0
        )
        view.update(words: [word], vocabIndex: VocabIndex.shared, language: "de-DE", pageContext: makeContext())
        view.layoutIfNeeded()
        let hit = view.hitTest(CGPoint(x: 200, y: 300), with: nil)
        #expect(hit !== view, "Hit on a word region should resolve to its UIControl subview, not the overlay")
    }
}

// MARK: — Phrase lookup map tests (Task 6)

@Suite struct LearnerOverlayPhraseLookupTests {

    private func phrase(_ kind: PhraseKind, indices: [Int]) -> OCRPhrase {
        OCRPhrase(
            text: indices.map { "w\($0)" }.joined(separator: " "),
            kind: kind,
            wordIndices: indices,
            lineIndices: [0],
            boundingBox: CGRect(x: 0, y: 0, width: 1, height: 0.1),
            confidence: 0.9
        )
    }

    @Test func buildPhraseLookup_singlePhrase_mapsAllIndices() {
        let p = phrase(.idiom, indices: [1, 2, 3])
        let map = LearnerOverlayView.buildPhraseLookup([p])
        #expect(map.count == 3)
        #expect(map[1] == p)
        #expect(map[2] == p)
        #expect(map[3] == p)
        #expect(map[0] == nil)
    }

    @Test func buildPhraseLookup_overlap_leftmostWins() {
        let leftmost = phrase(.idiom, indices: [2, 3])
        let rightmost = phrase(.compound, indices: [3, 4])
        let map = LearnerOverlayView.buildPhraseLookup([rightmost, leftmost])
        // Both claim index 3; the one whose leftmost (2) is smaller wins.
        #expect(map[3] == leftmost)
        #expect(map[2] == leftmost)
        #expect(map[4] == rightmost)
    }
}

// MARK: — LearnerEvents tests

@Suite struct LearnerEventsTests {

    // Test 4: wordTapped publisher fires
    @Test @MainActor func wordTapped_publisherFires() async {
        let expectationMet = await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = LearnerEvents.shared.wordTapped
                .first()
                .sink { _ in continuation.resume(returning: true) }
            _ = cancellable

            let ctx = LearnerPageContext(sourceId: "s", mangaId: "m", chapterId: "c", pageIndex: 0)
            let event = WordTapEvent(surfaceForm: "Buch", lemma: "buch", language: "de-DE", pageContext: ctx)
            LearnerEvents.shared.wordTapped.send(event)
        }
        #expect(expectationMet == true)
    }

    // Test 5b: phraseTapped publisher fires
    @Test @MainActor func phraseTapped_publisherFires() async {
        let expectationMet = await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = LearnerEvents.shared.phraseTapped
                .first()
                .sink { _ in continuation.resume(returning: true) }
            _ = cancellable

            let ctx = LearnerPageContext(sourceId: "s", mangaId: "m", chapterId: "c", pageIndex: 0)
            let phrase = OCRPhrase(
                text: "kick the bucket",
                kind: .idiom,
                wordIndices: [0, 1, 2],
                lineIndices: [0],
                boundingBox: CGRect(x: 0, y: 0, width: 0.5, height: 0.05),
                confidence: 0.9
            )
            let event = PhraseTapEvent(phrase: phrase, language: "en-US", pageContext: ctx)
            LearnerEvents.shared.phraseTapped.send(event)
        }
        #expect(expectationMet == true)
    }

    // Test 5: vocabChanged publisher fires
    @Test @MainActor func vocabChanged_publisherFires() async {
        let expectationMet = await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = LearnerEvents.shared.vocabChanged
                .first()
                .sink { _ in continuation.resume(returning: true) }
            _ = cancellable

            LearnerEvents.shared.vocabChanged.send()
        }
        #expect(expectationMet == true)
    }
}

// MARK: — VocabIndex tests

@Suite struct VocabIndexTests {

    // Test 6: unknown word returns nil level
    @Test @MainActor func level_unknownWord_returnsNil() {
        let index = VocabIndex.shared
        let id = VocabularyEntryObject.Identifier(language: "de-DE", lemma: "unknownxyz123")
        #expect(index.level(for: id) == nil)
    }

    // Test 7: isDone returns false for unknown word
    @Test @MainActor func isDone_unknownWord_returnsFalse() {
        let index = VocabIndex.shared
        let id = VocabularyEntryObject.Identifier(language: "de-DE", lemma: "unknownxyz456")
        #expect(index.isDone(for: id) == false)
    }
}

// MARK: — LearnerCoordinator no-op when disabled

@Suite struct LearnerCoordinatorTests {

    // Test 8: coordinator is a no-op when Learner is disabled for the manga
    @Test @MainActor func imageDidLoad_learnerOff_noOverlay() async {
        let mangaId = "coordinator-test-manga"
        // Use new tri-state key (Task 1)
        UserDefaults.standard.set("off", forKey: "Learner.mode.\(mangaId)")
        defer { UserDefaults.standard.removeObject(forKey: "Learner.mode.\(mangaId)") }

        let container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let pageView = ReaderPageView()
        pageView.frame = container.bounds

        let ctx = LearnerPageContext(sourceId: "src", mangaId: mangaId, chapterId: "ch1", pageIndex: 0)
        let image = UIImage()

        // Should be a no-op — overlay should NOT be added
        await LearnerOverlayCoordinator.shared.imageDidLoad(image, context: ctx, container: pageView)

        // Give any async tasks a chance to run
        try? await Task.sleep(nanoseconds: 100_000_000)

        let overlayCount = pageView.imageView.subviews.filter { $0 is LearnerOverlayView }.count
        #expect(overlayCount == 0)
    }
}

// MARK: — LearnerGate tri-state matrix (Task 1)

@Suite struct LearnerGateTests {

    // Helper: clean up UserDefaults keys after each test
    private func withCleanDefaults(mangaId: String, global: Bool, mode: String?, body: () -> Void) {
        let modeKey = LearnerGate.modeKey(for: mangaId)
        UserDefaults.standard.set(global, forKey: "Learner.globallyEnabled")
        if let mode {
            UserDefaults.standard.set(mode, forKey: modeKey)
        } else {
            UserDefaults.standard.removeObject(forKey: modeKey)
        }
        body()
        UserDefaults.standard.removeObject(forKey: modeKey)
        UserDefaults.standard.removeObject(forKey: "Learner.globallyEnabled")
    }

    // 9 combinations: (global ∈ {on, off}) × (perManga ∈ {inherit, on, off})
    // Note: global=on/inherit, global=off/inherit — inherit means result == global

    @Test func tristate_globalOn_modeInherit_enabled() {
        withCleanDefaults(mangaId: "m-t1", global: true, mode: nil) {
            #expect(LearnerGate.isEnabled(mangaId: "m-t1") == true)
        }
    }

    @Test func tristate_globalOn_modeOn_enabled() {
        withCleanDefaults(mangaId: "m-t2", global: true, mode: "on") {
            #expect(LearnerGate.isEnabled(mangaId: "m-t2") == true)
        }
    }

    @Test func tristate_globalOn_modeOff_disabled() {
        withCleanDefaults(mangaId: "m-t3", global: true, mode: "off") {
            #expect(LearnerGate.isEnabled(mangaId: "m-t3") == false)
        }
    }

    @Test func tristate_globalOff_modeInherit_disabled() {
        withCleanDefaults(mangaId: "m-t4", global: false, mode: nil) {
            #expect(LearnerGate.isEnabled(mangaId: "m-t4") == false)
        }
    }

    @Test func tristate_globalOff_modeOn_enabled() {
        withCleanDefaults(mangaId: "m-t5", global: false, mode: "on") {
            #expect(LearnerGate.isEnabled(mangaId: "m-t5") == true)
        }
    }

    @Test func tristate_globalOff_modeOff_disabled() {
        withCleanDefaults(mangaId: "m-t6", global: false, mode: "off") {
            #expect(LearnerGate.isEnabled(mangaId: "m-t6") == false)
        }
    }

    // Legacy migration: Bool true → mode "on", old key removed
    @Test func migration_legacyTrue_migratestoOn() {
        let mangaId = "m-legacy-true"
        let legacyKey = LearnerGate.legacyBoolKey(for: mangaId)
        let newKey = LearnerGate.modeKey(for: mangaId)
        // Setup legacy state
        UserDefaults.standard.set(true, forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: newKey)

        let enabled = LearnerGate.isEnabled(mangaId: mangaId)

        #expect(enabled == true)
        #expect(UserDefaults.standard.string(forKey: newKey) == "on")
        #expect(UserDefaults.standard.object(forKey: legacyKey) == nil)

        // Cleanup
        UserDefaults.standard.removeObject(forKey: newKey)
    }

    // Legacy migration: Bool false → new key absent (inherit), old key removed
    @Test func migration_legacyFalse_removesOldKey() {
        let mangaId = "m-legacy-false"
        let legacyKey = LearnerGate.legacyBoolKey(for: mangaId)
        let newKey = LearnerGate.modeKey(for: mangaId)
        // Setup legacy state
        UserDefaults.standard.set(false, forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: newKey)
        UserDefaults.standard.set(false, forKey: "Learner.globallyEnabled")

        let enabled = LearnerGate.isEnabled(mangaId: mangaId)

        // false legacy + global off → inherit → disabled
        #expect(enabled == false)
        // New key should be absent (inherit, not "off")
        #expect(UserDefaults.standard.object(forKey: newKey) == nil)
        // Old key must be gone
        #expect(UserDefaults.standard.object(forKey: legacyKey) == nil)

        // Cleanup
        UserDefaults.standard.removeObject(forKey: "Learner.globallyEnabled")
    }

    // mode() helper returns the correct enum value
    @Test func mode_returnsCorrectEnum() {
        let mangaId = "m-mode-enum"
        let key = LearnerGate.modeKey(for: mangaId)
        UserDefaults.standard.set("on", forKey: key)
        #expect(LearnerGate.mode(for: mangaId) == .on)
        UserDefaults.standard.set("off", forKey: key)
        #expect(LearnerGate.mode(for: mangaId) == .off)
        UserDefaults.standard.removeObject(forKey: key)
        #expect(LearnerGate.mode(for: mangaId) == .inherit)
    }
}
