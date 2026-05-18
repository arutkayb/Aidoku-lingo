//
//  WordLookupViewModel.swift
//  Aidoku (iOS)
//
//  ObservableObject view model backing WordLookupSheet.
//  Handles translation loading, vocab membership, familiarity, and done-locking.
//

import Foundation
import Combine
#if canImport(Translation)
import Translation
#endif

@MainActor
final class WordLookupViewModel: ObservableObject {

    // MARK: — Inputs

    /// The displayed surface form. Mutable in vocab-only mode so `applyEdits()`
    /// can refresh the header after the user edits the word itself.
    @Published var surfaceForm: String
    let lemma: String
    let language: String
    let mangaId: String
    let sourceId: String

    // MARK: — State

    @Published var translation: WordTranslation?
    @Published var isInVocab: Bool = false
    @Published var familiarity: Int16 = 0
    @Published var isDone: Bool = false
    @Published var loadError: TranslationError?
    @Published var isLoading: Bool = false
    /// Set when the lookup represents a phrase (idiom, compound, phrasal verb, named entity).
    /// `nil` for single-word lookups. Drives the sheet's chip rendering.
    @Published var phraseKind: PhraseKind?

    // MARK: — Edit state (vocab-only mode)

    /// Editable copy of the displayed surface form. Seeded in `init(entry:)` only.
    @Published var editableSurfaceForm: String = ""
    /// Editable copy of the entry's translation. Seeded in `init(entry:)` only.
    @Published var editableTranslation: String = ""
    /// Editable copy of the entry's notes field. Seeded in `init(entry:)` only.
    @Published var editableNotes: String = ""
    /// Weak reference used by `applyEdits()` to locate the CoreData row.
    private weak var editableEntry: VocabularyEntryObject?

    // MARK: — Init

    init(event: WordTapEvent) {
        self.surfaceForm = event.surfaceForm
        self.lemma = LearnerStrings.normalizeLemma(event.surfaceForm)
        self.language = event.language
        self.mangaId = event.pageContext.mangaId
        self.sourceId = event.pageContext.sourceId
        loadVocabState()
    }

    /// Init for vocab-only mode (from Vocabulary list — no page context needed).
    init(entry: VocabularyEntryObject) {
        self.surfaceForm = entry.surfaceForm
        self.lemma = entry.lemma
        self.language = entry.language
        self.mangaId = entry.sourceMangaId ?? ""
        self.sourceId = entry.sourceMangaSourceId ?? ""
        self.isInVocab = true
        self.familiarity = entry.progress?.level ?? 0
        self.isDone = entry.progress?.done ?? false
        // Use cached translation if available
        if let t = entry.translation {
            self.translation = WordTranslation(lemma: entry.lemma, translation: t)
        }
        // Seed editable fields
        self.editableSurfaceForm = entry.surfaceForm
        self.editableTranslation = entry.translation ?? ""
        self.editableNotes = entry.notes ?? ""
        self.editableEntry = entry
    }

    // MARK: — Vocab state

    private func loadVocabState() {
        if let entry = CoreDataManager.shared.getVocabularyEntry(language: language, lemma: lemma) {
            isInVocab = true
            familiarity = entry.progress?.level ?? 0
            isDone = entry.progress?.done ?? false
            if let t = entry.translation {
                translation = WordTranslation(lemma: lemma, translation: t)
            }
        }
    }

    // MARK: — Translation

    /// Optional service injection for tests. Production reads
    /// `TranslationServiceFactory.shared.service` per call.
    var translationService: (any TranslationService)?

    private func resolveService() -> any TranslationService {
        translationService ?? TranslationServiceFactory.shared.service
    }

    func loadTranslation() async {
        guard translation == nil else { return }
        isLoading = true
        loadError = nil
        do {
            let targetLang = UserDefaults.standard.string(forKey: "Learner.targetLanguage") ?? "en"
            let result = try await resolveService()
                .translateWord(lemma, sourceLanguage: language, targetLanguage: targetLang)
            translation = result
            // Cache in CoreData if word is in vocab
            if isInVocab {
                _ = CoreDataManager.shared.upsertVocabularyEntry(
                    language: language,
                    lemma: lemma,
                    surfaceForm: surfaceForm,
                    translation: result.translation,
                    sourceMangaId: mangaId.isEmpty ? nil : mangaId,
                    sourceMangaSourceId: sourceId.isEmpty ? nil : sourceId
                )
            }
        } catch let err as TranslationError {
            loadError = err
        } catch {
            loadError = .networkError(underlying: error)
        }
        isLoading = false
    }

    // MARK: — Phrase lookup

    /// Translate a phrase (verbatim text including whitespace) and publish the result
    /// alongside `phraseKind` so the sheet renders the appropriate chip.
    func lookup(
        phrase: String,
        kind: PhraseKind,
        sourceLanguage: String,
        targetLanguage: String
    ) async {
        phraseKind = kind
        isLoading = true
        loadError = nil
        do {
            let result = try await resolveService()
                .translateWord(phrase, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
            translation = result
        } catch let err as TranslationError {
            loadError = err
        } catch {
            loadError = .networkError(underlying: error)
        }
        isLoading = false
    }

    // MARK: — Vocab membership

    func toggleVocab() async {
        if isInVocab {
            // Remove
            if let entry = CoreDataManager.shared.getVocabularyEntry(language: language, lemma: lemma) {
                CoreDataManager.shared.removeVocabularyEntry(entry)
                isInVocab = false
                familiarity = 0
                isDone = false
            }
        } else {
            // Add
            _ = CoreDataManager.shared.upsertVocabularyEntry(
                language: language,
                lemma: lemma,
                surfaceForm: surfaceForm,
                translation: translation?.translation,
                sourceMangaId: mangaId.isEmpty ? nil : mangaId,
                sourceMangaSourceId: sourceId.isEmpty ? nil : sourceId
            )
            isInVocab = true
        }
        LearnerEvents.shared.vocabChanged.send()
    }

    // MARK: — Familiarity

    func setFamiliarity(_ level: Int16) async {
        guard isInVocab,
              let entry = CoreDataManager.shared.getVocabularyEntry(language: language, lemma: lemma) else { return }
        CoreDataManager.shared.setFamiliarity(entry, level: level)
        familiarity = level
        LearnerEvents.shared.vocabChanged.send()
    }

    // MARK: — Done

    func markDone() async {
        guard isInVocab,
              let entry = CoreDataManager.shared.getVocabularyEntry(language: language, lemma: lemma) else { return }
        CoreDataManager.shared.setDone(entry)
        isDone = true
        familiarity = 3
        LearnerEvents.shared.vocabChanged.send()
    }

    // MARK: — Edit (vocab-only mode)

    /// Persists `editableSurfaceForm`, `editableTranslation`, and `editableNotes`
    /// to CoreData. The lemma stays immutable (it's the row's identity);
    /// surfaceForm is the user-visible spelling and is freely editable.
    /// Call from the sheet's "Save" toolbar action.
    func applyEdits() async {
        guard let entry = editableEntry else { return }
        let newTranslation = editableTranslation.isEmpty ? nil : editableTranslation
        let newNotes = editableNotes.isEmpty ? nil : editableNotes
        let trimmedSurface = editableSurfaceForm.trimmingCharacters(in: .whitespacesAndNewlines)
        let newSurface = trimmedSurface.isEmpty ? nil : trimmedSurface
        CoreDataManager.shared.updateVocabularyEntry(
            entry,
            translation: newTranslation,
            notes: newNotes,
            surfaceForm: newSurface
        )
        // Refresh published state so the header + list re-render immediately.
        if let s = newSurface { surfaceForm = s }
        if let t = newTranslation {
            translation = WordTranslation(lemma: lemma, translation: t)
        } else {
            translation = nil
        }
        LearnerEvents.shared.vocabChanged.send()
    }

    /// Reverts editable fields to the persisted values (Cancel action).
    func revertEdits() {
        editableSurfaceForm = editableEntry?.surfaceForm ?? surfaceForm
        editableTranslation = editableEntry?.translation ?? ""
        editableNotes = editableEntry?.notes ?? ""
    }

    // MARK: — Sentence translation hand-off

    func requestSentenceTranslation(event: WordTapEvent) {
        LearnerEvents.shared.sentenceTranslateRequested.send(event)
    }

    // MARK: — Apple Translation framework

    #if canImport(Translation)
    @available(iOS 18.0, *)
    func loadTranslation(using session: TranslationSession) async {
        guard translation == nil else { return }
        isLoading = true
        loadError = nil
        do {
            let response = try await session.translate(lemma)
            let result = WordTranslation(lemma: lemma, translation: response.targetText)
            translation = result
            if isInVocab {
                _ = CoreDataManager.shared.upsertVocabularyEntry(
                    language: language,
                    lemma: lemma,
                    surfaceForm: surfaceForm,
                    translation: result.translation,
                    sourceMangaId: mangaId.isEmpty ? nil : mangaId,
                    sourceMangaSourceId: sourceId.isEmpty ? nil : sourceId
                )
            }
        } catch {
            loadError = .networkError(underlying: error)
        }
        isLoading = false
    }
    #endif
}
