//
//  CoreDataManager+Vocabulary.swift
//  Aidoku
//
//  CoreData manager extension for vocabulary, familiarity, and flashcard entities.
//  Follows the CoreDataManager+Manga.swift conventions:
//  - Optional context arg, default to container.viewContext
//  - try? for reads, try? context.save() after background writes
//

import CoreData

extension CoreDataManager {

    // MARK: — VocabularyEntry

    /// Fetch a single vocab entry by (language, lemma) composite key.
    /// `lemma` is normalised (lowercase + whitespace-trim) before lookup.
    func getVocabularyEntry(
        language: String,
        lemma: String,
        context: NSManagedObjectContext? = nil
    ) -> VocabularyEntryObject? {
        let ctx = context ?? self.context
        let normalizedLemma = VocabularyEntryObject.normalize(lemma)
        let request = VocabularyEntryObject.fetchRequest()
        request.predicate = NSPredicate(format: "language == %@ AND lemma == %@", language, normalizedLemma)
        request.fetchLimit = 1
        return (try? ctx.fetch(request))?.first
    }

    /// Fetch all vocab entries, optionally filtered by language.
    func getAllVocabulary(
        language: String? = nil,
        context: NSManagedObjectContext? = nil
    ) -> [VocabularyEntryObject] {
        let ctx = context ?? self.context
        let request = VocabularyEntryObject.fetchRequest()
        if let language {
            request.predicate = NSPredicate(format: "language == %@", language)
        }
        request.sortDescriptors = [NSSortDescriptor(key: "dateAdded", ascending: false)]
        return (try? ctx.fetch(request)) ?? []
    }

    /// Fetch entries eligible for flashcard review: not done, ordered by level ASC then lastReviewedAt ASC.
    func getFlashcardQueue(
        language: String? = nil,
        limit: Int? = nil,
        context: NSManagedObjectContext? = nil
    ) -> [VocabularyEntryObject] {
        let ctx = context ?? self.context
        let request = VocabularyEntryObject.fetchRequest()
        var predicates: [NSPredicate] = [NSPredicate(format: "progress.done == NO")]
        if let language {
            predicates.append(NSPredicate(format: "language == %@", language))
        }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        request.sortDescriptors = [
            NSSortDescriptor(key: "progress.level", ascending: true),
            NSSortDescriptor(key: "progress.lastReviewedAt", ascending: true)
        ]
        if let limit { request.fetchLimit = limit }
        return (try? ctx.fetch(request)) ?? []
    }

    /// Insert or update a vocab entry by (language, lemma). Returns the object.
    /// `lemma` is normalised (lowercase + whitespace-trim) at insert time per Decision Register #6.
    @discardableResult
    func upsertVocabularyEntry(
        language: String,
        lemma: String,
        surfaceForm: String,
        translation: String?,
        sourceMangaId: String?,
        sourceMangaSourceId: String?,
        context: NSManagedObjectContext? = nil
    ) -> VocabularyEntryObject {
        let ctx = context ?? self.context
        let normalizedLemma = VocabularyEntryObject.normalize(lemma)
        // Clean the surface form so OCR/stutter junk like "NEIN..!" is stored as
        // "NEIN" (case preserved). Falls back to the raw input if the clean version
        // would be empty — never blank out the display column.
        let cleanedSurface = VocabularyEntryObject.cleanSurfaceForm(surfaceForm)
        let displaySurface = cleanedSurface.isEmpty ? surfaceForm : cleanedSurface
        let existing = getVocabularyEntry(language: language, lemma: normalizedLemma, context: ctx)
        let entry = existing ?? VocabularyEntryObject(context: ctx)
        if existing == nil {
            entry.id = UUID()
            entry.dateAdded = Date()
            // Create associated progress row
            let progress = FamiliarityProgressObject(context: ctx)
            progress.level = 0
            progress.correctAnswers = 0
            progress.done = false
            progress.entry = entry
            entry.progress = progress
        }
        entry.load(
            language: language,
            lemma: normalizedLemma,
            surfaceForm: displaySurface,
            translation: translation,
            sourceMangaId: sourceMangaId,
            sourceMangaSourceId: sourceMangaSourceId
        )
        try? ctx.save()
        return entry
    }

    /// Returns true if at least one vocab entry exists in the store. Used by the
    /// tab bar to decide whether to show the Learner tab regardless of the global
    /// toggle (a user with saved vocab should always be able to reach it).
    func hasAnyVocabulary(context: NSManagedObjectContext? = nil) -> Bool {
        let ctx = context ?? self.context
        let request = VocabularyEntryObject.fetchRequest()
        request.fetchLimit = 1
        return ((try? ctx.count(for: request)) ?? 0) > 0
    }

    /// Update the mutable fields of an existing vocab entry.
    /// `translation`, `notes`, and the display `surfaceForm` may be changed; the
    /// `lemma`/`language` pair remains immutable since it's the row identity.
    /// Passing `nil` for `surfaceForm` leaves the existing value untouched.
    func updateVocabularyEntry(
        _ entry: VocabularyEntryObject,
        translation: String?,
        notes: String?,
        surfaceForm: String? = nil,
        context: NSManagedObjectContext? = nil
    ) {
        let ctx = context ?? self.context
        let entryInCtx = ctx.object(with: entry.objectID) as? VocabularyEntryObject ?? entry
        entryInCtx.translation = translation
        entryInCtx.notes = notes
        if let surfaceForm, !surfaceForm.isEmpty {
            entryInCtx.surfaceForm = surfaceForm
        }
        try? ctx.save()
    }

    /// Remove a vocab entry (cascades to progress and flashcard state).
    func removeVocabularyEntry(
        _ entry: VocabularyEntryObject,
        context: NSManagedObjectContext? = nil
    ) {
        let ctx = context ?? self.context
        ctx.delete(entry)
        try? ctx.save()
    }

    // MARK: — FamiliarityProgress

    /// Directly set the familiarity level for a vocab entry (clamped to 0…3).
    func setFamiliarity(
        _ entry: VocabularyEntryObject,
        level: Int16,
        context: NSManagedObjectContext? = nil
    ) {
        let ctx = context ?? self.context
        let entryInCtx = ctx.object(with: entry.objectID) as? VocabularyEntryObject ?? entry
        guard let progress = entryInCtx.progress else { return }
        progress.level = min(max(level, 0), 3)
        try? ctx.save()
    }

    // MARK: — Flashcard review

    /// Record a flashcard review result.
    /// Rule: if correct and !done and level < 3 → level += 1; always update lastReviewedAt; always increment correctAnswers if correct.
    func markFlashcardReview(
        _ entry: VocabularyEntryObject,
        correct: Bool,
        context: NSManagedObjectContext? = nil
    ) {
        let ctx = context ?? self.context
        let entryInCtx = ctx.object(with: entry.objectID) as? VocabularyEntryObject ?? entry
        guard let progress = entryInCtx.progress else { return }
        if correct {
            progress.correctAnswers += 1
            if !progress.done && progress.level < 3 {
                progress.level += 1
            }
        }
        progress.lastReviewedAt = Date()
        try? ctx.save()
    }

    /// Mark a word as "done" — locks level at 3, excludes from queue.
    func setDone(
        _ entry: VocabularyEntryObject,
        context: NSManagedObjectContext? = nil
    ) {
        let ctx = context ?? self.context
        let entryInCtx = ctx.object(with: entry.objectID) as? VocabularyEntryObject ?? entry
        guard let progress = entryInCtx.progress else { return }
        progress.done = true
        progress.level = 3
        try? ctx.save()
    }

    // MARK: — Bulk delete

    /// Removes all vocabulary entries and their associated progress and flashcard state rows.
    /// Uses context-level deletion (not NSBatchDeleteRequest) so cascade rules are respected
    /// and the method works correctly against in-memory stores (e.g., during unit tests).
    func clearVocabulary(context: NSManagedObjectContext? = nil) {
        let ctx = context ?? self.context
        let entries = (try? ctx.fetch(VocabularyEntryObject.fetchRequest())) ?? []
        for entry in entries { ctx.delete(entry) }
        let progress = (try? ctx.fetch(FamiliarityProgressObject.fetchRequest())) ?? []
        for row in progress { ctx.delete(row) }
        let flashcards = (try? ctx.fetch(FlashcardStateObject.fetchRequest())) ?? []
        for row in flashcards { ctx.delete(row) }
        try? ctx.save()
    }
}
