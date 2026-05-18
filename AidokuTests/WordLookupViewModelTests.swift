//
//  WordLookupViewModelTests.swift
//  Aidoku
//
//  Swift Testing cases for WordLookupViewModel.
//  Uses in-memory CoreData stack and stub TranslationService.
//

import Foundation
import CoreData
import Combine
import Testing
@testable import Aidoku

// MARK: — Helper
// (Canonical `StubTranslationService` lives in `TranslationServiceTests.swift`;
//  duplicating it here triggers an invalid-redeclaration error.)

private func makeEvent(word: String = "Buch", manga: String = "test-manga-wlvm") -> WordTapEvent {
    let ctx = LearnerPageContext(sourceId: "src", mangaId: manga, chapterId: "ch1", pageIndex: 0)
    return WordTapEvent(surfaceForm: word, lemma: LearnerStrings.normalizeLemma(word), language: "de-DE", pageContext: ctx)
}

// MARK: — Tests

@Suite struct WordLookupViewModelTests {

    // Test 1: normalizeLemma matches VocabularyEntryObject.normalize so the overlay
    // badge lookup never diverges from the storage key.
    // Task 4: edge punctuation is now stripped; in-word punctuation preserved.
    @Test func normalizeLemma_matchesStorageRule() {
        #expect(LearnerStrings.normalizeLemma("  Buch  ") == "buch")
        #expect(LearnerStrings.normalizeLemma("BUCH") == "buch")
        // Edge punctuation stripped: "Buch," and "Buch" both normalize to "buch"
        #expect(LearnerStrings.normalizeLemma("Buch.") == "buch")
        #expect(LearnerStrings.normalizeLemma("Buch,") == "buch")
        // In-word apostrophe preserved
        #expect(LearnerStrings.normalizeLemma("it's") == "it's")
        // Symmetry with the entity-level normalizer (single source of truth).
        #expect(LearnerStrings.normalizeLemma("Tür,") == VocabularyEntryObject.normalize("Tür,"))
    }

    // Test 1b: WordTapEvent with surface "Tür," produces lemma "tür" (no comma). (Task 4)
    @Test func wordTapEvent_surfaceWithTrailingComma_lemmaStripped() {
        let event = makeEvent(word: "Tür,")
        #expect(event.lemma == "tür")
    }

    // Test 2: fresh event — not in vocab initially
    @Test @MainActor func init_freshEvent_notInVocab() {
        let vm = WordLookupViewModel(event: makeEvent())
        #expect(vm.isInVocab == false)
        #expect(vm.familiarity == 0)
        #expect(vm.isDone == false)
    }

    // Test 3: toggleVocab adds entry; second call removes it
    @Test @MainActor func toggleVocab_addsAndRemovesEntry() async {
        let ctx = makeInMemoryContainer()
        let vm = WordLookupViewModel(event: makeEvent(word: "Haus"))
        let lemma = vm.lemma
        let lang = vm.language

        // Add
        await vm.toggleVocab()
        #expect(vm.isInVocab == true)
        let entry = CoreDataManager.shared.getVocabularyEntry(language: lang, lemma: lemma, context: ctx.viewContext)
        #expect(entry != nil)

        // Remove
        await vm.toggleVocab()
        #expect(vm.isInVocab == false)
        let removed = CoreDataManager.shared.getVocabularyEntry(language: lang, lemma: lemma, context: ctx.viewContext)
        #expect(removed == nil)
    }

    // Test 4: setFamiliarity persists and fires vocabChanged
    @Test @MainActor func setFamiliarity_persistsLevel() async {
        let ctx = makeInMemoryContainer()
        let vm = WordLookupViewModel(event: makeEvent(word: "Tisch"))

        // First add to vocab
        await vm.toggleVocab()
        #expect(vm.isInVocab == true)

        // Set familiarity
        await vm.setFamiliarity(2)
        #expect(vm.familiarity == 2)

        let entry = CoreDataManager.shared.getVocabularyEntry(
            language: vm.language, lemma: vm.lemma, context: ctx.viewContext
        )
        #expect(entry?.progress?.level == 2)
    }

    // Test 5: applyEdits persists translation + notes (Task 5)
    @Test @MainActor func applyEdits_persistsTranslationAndNotes() async {
        _ = makeInMemoryContainer()
        // Insert a vocab entry to edit
        let entry = CoreDataManager.shared.upsertVocabularyEntry(
            language: "de-DE",
            lemma: "welt",
            surfaceForm: "Welt",
            translation: "world",
            sourceMangaId: nil,
            sourceMangaSourceId: nil
        )
        let vm = WordLookupViewModel(entry: entry)
        #expect(vm.editableTranslation == "world")
        #expect(vm.editableNotes == "")

        vm.editableTranslation = "earth"
        vm.editableNotes = "seen on page 3"
        await vm.applyEdits()

        let updated = CoreDataManager.shared.getVocabularyEntry(language: "de-DE", lemma: "welt")
        #expect(updated?.translation == "earth")
        #expect(updated?.notes == "seen on page 3")
        #expect(vm.translation?.translation == "earth")
    }

    // Test 5b: revertEdits restores original values without saving (Task 5)
    @Test @MainActor func revertEdits_restoresOriginalValues() async {
        _ = makeInMemoryContainer()
        let entry = CoreDataManager.shared.upsertVocabularyEntry(
            language: "de-DE",
            lemma: "baum",
            surfaceForm: "Baum",
            translation: "tree",
            sourceMangaId: nil,
            sourceMangaSourceId: nil
        )
        let vm = WordLookupViewModel(entry: entry)
        vm.editableTranslation = "something else"
        vm.editableNotes = "a note"
        vm.revertEdits()

        #expect(vm.editableTranslation == "tree")
        #expect(vm.editableNotes == "")
    }

    // Test 5c: edit mode is gated to vocab-only init — event init does NOT seed editableEntry (Task 5)
    @Test @MainActor func applyEdits_eventInit_isNoOp() async {
        let vm = WordLookupViewModel(event: makeEvent(word: "Feuer"))
        vm.editableTranslation = "fire"
        // applyEdits should be a no-op since editableEntry is nil (event init path)
        await vm.applyEdits()
        // No crash, no DB row written for this word via applyEdits
        let entry = CoreDataManager.shared.getVocabularyEntry(language: "de-DE", lemma: "feuer")
        #expect(entry == nil)
    }

    // Test 7: phrase lookup calls translateWord with the verbatim phrase string. (Task 4)
    @Test @MainActor func phraseLookup_callsTranslateWordWithVerbatimPhrase() async {
        let stub = StubTranslationService()
        stub.wordResult = WordTranslation(lemma: "kick the bucket", translation: "ölmek")
        let vm = WordLookupViewModel(event: makeEvent(word: "kick"))
        vm.translationService = stub

        await vm.lookup(
            phrase: "kick the bucket",
            kind: .idiom,
            sourceLanguage: "en-US",
            targetLanguage: "tr-TR"
        )
        #expect(stub.wordCallCount == 1)
        #expect(vm.translation?.translation == "ölmek")
        #expect(vm.phraseKind == .idiom)
    }

    // Test 8: cache hit short-circuits via CachingTranslationService. (Task 4)
    @Test @MainActor func phraseLookup_cachedSecondCall_returnsImmediately() async {
        let stub = StubTranslationService()
        stub.wordResult = WordTranslation(lemma: "kick the bucket", translation: "ölmek")
        let caching = CachingTranslationService(wrapping: stub)
        let vm1 = WordLookupViewModel(event: makeEvent(word: "kick"))
        vm1.translationService = caching
        let vm2 = WordLookupViewModel(event: makeEvent(word: "kick"))
        vm2.translationService = caching

        await vm1.lookup(phrase: "kick the bucket", kind: .idiom, sourceLanguage: "en-US", targetLanguage: "tr-TR")
        await vm2.lookup(phrase: "kick the bucket", kind: .idiom, sourceLanguage: "en-US", targetLanguage: "tr-TR")
        #expect(stub.wordCallCount == 1, "Caching layer should reuse the phrase translation")
    }

    // Test 9: phraseKind is published verbatim. (Task 4)
    @Test @MainActor func phraseLookup_publishedKindEqualsInput() async {
        let stub = StubTranslationService()
        let vm = WordLookupViewModel(event: makeEvent(word: "look"))
        vm.translationService = stub
        await vm.lookup(phrase: "look out", kind: .phrasalVerb, sourceLanguage: "en-US", targetLanguage: "tr-TR")
        #expect(vm.phraseKind == .phrasalVerb)
    }

    // Test 6 (original): requestSentenceTranslation emits event
    @Test @MainActor func requestSentenceTranslation_emitsEvent() async {
        let vm = WordLookupViewModel(event: makeEvent())
        let event = makeEvent()

        let fired = await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = LearnerEvents.shared.sentenceTranslateRequested
                .first()
                .sink { _ in
                    continuation.resume(returning: true)
                    cancellable?.cancel()
                }
            vm.requestSentenceTranslation(event: event)
        }
        #expect(fired == true)
    }
}
