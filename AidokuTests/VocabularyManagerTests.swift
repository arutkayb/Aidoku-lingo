//
//  VocabularyManagerTests.swift
//  Aidoku
//
//  Swift Testing cases for CoreDataManager+Vocabulary and BackupVocabularyEntry.
//  Uses an in-memory NSPersistentContainer so tests don't touch the real store.
//

import Foundation
import CoreData
import Testing
@testable import Aidoku

// MARK: — Tests

@Suite struct VocabularyManagerTests {

    // MARK: Test 1 — create + fetch round-trip

    @Test func createAndFetch_roundTrip() throws {
        let container = makeInMemoryContainer()
        let ctx = container.viewContext

        // Create
        let entry = CoreDataManager.shared.upsertVocabularyEntry(
            language: "de-DE",
            lemma: "buch",
            surfaceForm: "Buch",
            translation: "book",
            sourceMangaId: "manga1",
            sourceMangaSourceId: "src1",
            context: ctx
        )

        // Fetch
        let fetched = CoreDataManager.shared.getVocabularyEntry(language: "de-DE", lemma: "buch", context: ctx)
        #expect(fetched != nil)
        #expect(fetched?.lemma == "buch")
        #expect(fetched?.surfaceForm == "Buch")
        #expect(fetched?.translation == "book")
        #expect(fetched?.language == "de-DE")
        #expect(fetched?.objectID == entry.objectID)
    }

    // MARK: Test 2 — familiarity caps at 3

    @Test func setFamiliarity_capsAtThree() throws {
        let container = makeInMemoryContainer()
        let ctx = container.viewContext

        let entry = CoreDataManager.shared.upsertVocabularyEntry(
            language: "de-DE", lemma: "wasser", surfaceForm: "Wasser",
            translation: "water", sourceMangaId: nil, sourceMangaSourceId: nil, context: ctx
        )
        // Call markFlashcardReview 4 times with correct=true
        for _ in 0..<4 {
            CoreDataManager.shared.markFlashcardReview(entry, correct: true, context: ctx)
        }
        let refetched = CoreDataManager.shared.getVocabularyEntry(language: "de-DE", lemma: "wasser", context: ctx)
        #expect(refetched?.progress?.level == 3) // level capped at 3
        #expect((refetched?.progress?.correctAnswers ?? 0) == 4) // correctAnswers always increments on correct, independent of level cap
    }

    // MARK: Test 3 — setDone locks level

    @Test func setDone_locksLevel() throws {
        let container = makeInMemoryContainer()
        let ctx = container.viewContext

        let entry = CoreDataManager.shared.upsertVocabularyEntry(
            language: "de-DE", lemma: "haus", surfaceForm: "Haus",
            translation: "house", sourceMangaId: nil, sourceMangaSourceId: nil, context: ctx
        )
        CoreDataManager.shared.setDone(entry, context: ctx)

        let fetched = CoreDataManager.shared.getVocabularyEntry(language: "de-DE", lemma: "haus", context: ctx)
        #expect(fetched?.progress?.done == true)
        #expect(fetched?.progress?.level == 3)

        // Subsequent review should NOT change level
        CoreDataManager.shared.markFlashcardReview(entry, correct: true, context: ctx)
        let refetched = CoreDataManager.shared.getVocabularyEntry(language: "de-DE", lemma: "haus", context: ctx)
        #expect(refetched?.progress?.level == 3)
    }

    // MARK: Test 4 — remove cascades progress

    @Test func removeEntry_cascadesProgress() throws {
        let container = makeInMemoryContainer()
        let ctx = container.viewContext

        let entry = CoreDataManager.shared.upsertVocabularyEntry(
            language: "de-DE", lemma: "katze", surfaceForm: "Katze",
            translation: "cat", sourceMangaId: nil, sourceMangaSourceId: nil, context: ctx
        )
        let progressId = entry.progress?.objectID

        CoreDataManager.shared.removeVocabularyEntry(entry, context: ctx)

        // Entry gone
        let fetched = CoreDataManager.shared.getVocabularyEntry(language: "de-DE", lemma: "katze", context: ctx)
        #expect(fetched == nil)

        // Progress gone (cascade delete from VocabularyEntry → progress)
        if let progressId {
            let progressFetch = try ctx.existingObject(with: progressId)
            #expect(progressFetch.isDeleted || progressFetch.managedObjectContext == nil)
        }
    }

    // MARK: Test 5 — backup round-trip

    @Test func backupRoundTrip_preservesEntries() throws {
        let container = makeInMemoryContainer()
        let ctx = container.viewContext

        // Create 3 entries with varying familiarity
        let words = [
            ("buch", "Buch", "book", Int16(0)),
            ("hund", "Hund", "dog", Int16(2)),
            ("katze", "Katze", "cat", Int16(1))
        ]
        for (lemma, surface, trans, level) in words {
            let entry = CoreDataManager.shared.upsertVocabularyEntry(
                language: "de-DE", lemma: lemma, surfaceForm: surface,
                translation: trans, sourceMangaId: nil, sourceMangaSourceId: nil, context: ctx
            )
            CoreDataManager.shared.setFamiliarity(entry, level: level, context: ctx)
        }

        // Serialize to backup
        let allEntries = CoreDataManager.shared.getAllVocabulary(language: "de-DE", context: ctx)
        #expect(allEntries.count == 3)
        let backupItems = allEntries.map { BackupVocabularyEntry(object: $0) }

        // Clear store
        for entry in allEntries {
            CoreDataManager.shared.removeVocabularyEntry(entry, context: ctx)
        }
        #expect(CoreDataManager.shared.getAllVocabulary(language: "de-DE", context: ctx).isEmpty)

        // Restore from backup
        for item in backupItems {
            _ = item.toObject(context: ctx)
        }
        try ctx.save()

        // Verify all 3 entries with correct familiarity
        let restored = CoreDataManager.shared.getAllVocabulary(language: "de-DE", context: ctx)
        #expect(restored.count == 3)
        let levelMap = Dictionary(uniqueKeysWithValues: restored.map { ($0.lemma, $0.progress?.level ?? -1) })
        #expect(levelMap["buch"] == 0)
        #expect(levelMap["hund"] == 2)
        #expect(levelMap["katze"] == 1)
    }

    // MARK: Test 6 — lemma normalization at insert time (Task 4: edge punctuation stripped)

    @Test func upsert_normalizesLemma_edgePunctuationStripped() throws {
        let container = makeInMemoryContainer()
        let ctx = container.viewContext

        // Insert with uppercase + surrounding whitespace + trailing '?'.
        // Task 4: trailing '?' is now stripped (edge punctuation removal).
        let entry = CoreDataManager.shared.upsertVocabularyEntry(
            language: "de-DE",
            lemma: "  Mädchen?  ",
            surfaceForm: "Mädchen?",
            translation: "girl",
            sourceMangaId: nil,
            sourceMangaSourceId: nil,
            context: ctx
        )
        // Whitespace trimmed, trailing '?' stripped, lowercased.
        #expect(entry.lemma == "mädchen")

        // Fetch with a differently-cased / punctuated form normalizes to same row.
        let same = CoreDataManager.shared.getVocabularyEntry(language: "de-DE", lemma: "MÄDCHEN?", context: ctx)
        #expect(same?.objectID == entry.objectID)
    }
}

// MARK: — VocabularyEntryObject.normalize unit tests (Task 4)

@Suite struct NormalizeTests {

    @Test func normalize_trailingComma_stripped() {
        #expect(VocabularyEntryObject.normalize("Tür,") == "tür")
    }

    @Test func normalize_leadingAndTrailingBangs_stripped() {
        #expect(VocabularyEntryObject.normalize("!!hello!!") == "hello")
    }

    @Test func normalize_apostropheInWord_preserved() {
        #expect(VocabularyEntryObject.normalize("it's") == "it's")
    }

    @Test func normalize_hyphenInWord_preserved() {
        #expect(VocabularyEntryObject.normalize("auto-mobile") == "auto-mobile")
    }

    @Test func normalize_whitespaceOnly_trimmed() {
        #expect(VocabularyEntryObject.normalize("  foo  ") == "foo")
    }

    @Test func normalize_trailingPeriod_stripped() {
        #expect(VocabularyEntryObject.normalize("foo.") == "foo")
    }

    @Test func normalize_japanesePunctuation_stripped() {
        // U+3001 IDEOGRAPHIC COMMA — Unicode category Po (punctuation, other)
        #expect(VocabularyEntryObject.normalize("日本語、") == "日本語")
    }

    @Test func normalize_allPunctuation_returnsEmpty() {
        #expect(VocabularyEntryObject.normalize("!!!") == "")
    }

    @Test func normalize_emptyString_returnsEmpty() {
        #expect(VocabularyEntryObject.normalize("") == "")
    }

    @Test func normalize_inWordDash_preserved() {
        // Leading and trailing dashes are stripped; interior dash preserved
        #expect(VocabularyEntryObject.normalize("-auto-mobile-") == "auto-mobile")
    }

    // Bug-report follow-up: stutter/ellipsis inside a tap surface form leaves an
    // unusable lemma when only the edges are stripped. The longest-segment rule
    // discards the leading single-letter stutter.
    @Test func normalize_stutterDoubleDotsPlusBang_keepsLongestSegment() {
        #expect(VocabularyEntryObject.normalize("F..FURCHTBAR!") == "furchtbar")
    }

    @Test func normalize_stutterEllipsis_keepsLongestSegment() {
        // Single Unicode ellipsis character (U+2026) is punctuation (Po) — splits the lemma.
        #expect(VocabularyEntryObject.normalize("N\u{2026}NEIN") == "nein")
    }

    @Test func normalize_interiorComma_keepsLongerHalf() {
        // OCR sometimes inserts a comma in the middle of a word; the longer half wins
        // (segments are ["Hel", "lo"] → longest "Hel" → "hel"). Documents the rule.
        #expect(VocabularyEntryObject.normalize("Hel,lo") == "hel")
    }

    // cleanSurfaceForm: the case-preserving sibling of normalize, used to store
    // the user-visible surface form on a vocab entry.
    @Test func cleanSurfaceForm_stutterAndBang_preservesCase() {
        #expect(VocabularyEntryObject.cleanSurfaceForm("NEIN..!") == "NEIN")
        #expect(VocabularyEntryObject.cleanSurfaceForm("F..FURCHTBAR!") == "FURCHTBAR")
    }

    @Test func cleanSurfaceForm_preservesInWordPunctuation() {
        #expect(VocabularyEntryObject.cleanSurfaceForm("It's") == "It's")
        #expect(VocabularyEntryObject.cleanSurfaceForm("Auto-Mobile") == "Auto-Mobile")
    }

    @Test func cleanSurfaceForm_emptyAfterStrip_returnsEmpty() {
        #expect(VocabularyEntryObject.cleanSurfaceForm("!!!") == "")
        #expect(VocabularyEntryObject.cleanSurfaceForm("") == "")
    }

    // MARK: — Phrase support (Task 5)

    @Test func upsert_phraseEntry_storesKind() throws {
        let container = makeInMemoryContainer()
        let ctx = container.viewContext
        let entry = CoreDataManager.shared.upsertVocabularyEntry(
            language: "en-US",
            lemma: "kick the bucket",
            surfaceForm: "Kick the Bucket",
            translation: "ölmek",
            sourceMangaId: nil,
            sourceMangaSourceId: nil,
            kind: "idiom",
            context: ctx
        )
        #expect(entry.kind == "idiom")
        let fetched = CoreDataManager.shared.getVocabularyEntry(language: "en-US", lemma: "kick the bucket", context: ctx)
        #expect(fetched?.kind == "idiom")
    }

    @Test func upsert_phraseEntry_dedupesByLanguageAndLemma() throws {
        let container = makeInMemoryContainer()
        let ctx = container.viewContext
        _ = CoreDataManager.shared.upsertVocabularyEntry(
            language: "en-US", lemma: "kick the bucket", surfaceForm: "kick the bucket",
            translation: "ölmek", sourceMangaId: nil, sourceMangaSourceId: nil,
            kind: "idiom", context: ctx
        )
        _ = CoreDataManager.shared.upsertVocabularyEntry(
            language: "en-US", lemma: "kick the bucket", surfaceForm: "KICK the BUCKET",
            translation: "ölmek (revised)", sourceMangaId: nil, sourceMangaSourceId: nil,
            kind: "idiom", context: ctx
        )
        let req = VocabularyEntryObject.fetchRequest()
        req.predicate = NSPredicate(format: "language == %@ AND lemma == %@", "en-US", "kick the bucket")
        let rows = try ctx.fetch(req)
        #expect(rows.count == 1)
    }

    @Test func normalize_preservesWhitespace() {
        #expect(VocabularyEntryObject.normalize("Kick the Bucket") == "kick the bucket")
        #expect(VocabularyEntryObject.normalize("  the  cat  ") == "the cat")
        // Single-word backwards compat.
        #expect(VocabularyEntryObject.normalize("Wort") == "wort")
        #expect(VocabularyEntryObject.normalize(" Wort ") == "wort")
    }

    @Test func cleanSurfaceForm_preservesWhitespaceMultiToken() {
        #expect(VocabularyEntryObject.cleanSurfaceForm("Kick the Bucket..!") == "Kick the Bucket")
        #expect(VocabularyEntryObject.cleanSurfaceForm("the cat") == "the cat")
        // Single-token backwards compat.
        #expect(VocabularyEntryObject.cleanSurfaceForm("NEIN..!") == "NEIN")
    }

    @Test func isPhrase_trueForWhitespaceLemma() throws {
        let container = makeInMemoryContainer()
        let ctx = container.viewContext
        let phrase = CoreDataManager.shared.upsertVocabularyEntry(
            language: "en-US", lemma: "kick the bucket", surfaceForm: "Kick the Bucket",
            translation: nil, sourceMangaId: nil, sourceMangaSourceId: nil,
            kind: "idiom", context: ctx
        )
        let word = CoreDataManager.shared.upsertVocabularyEntry(
            language: "en-US", lemma: "buch", surfaceForm: "Buch",
            translation: nil, sourceMangaId: nil, sourceMangaSourceId: nil,
            context: ctx
        )
        #expect(phrase.isPhrase == true)
        #expect(word.isPhrase == false)
    }
}

