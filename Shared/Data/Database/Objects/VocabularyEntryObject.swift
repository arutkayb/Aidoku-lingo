//
//  VocabularyEntryObject.swift
//  Aidoku
//
//  Hand-written NSManagedObject subclass for VocabularyEntry.
//  Auto-generated CoreData properties (+CoreDataProperties) are produced by Xcode at build time.
//

import Foundation
import CoreData

@objc(VocabularyEntryObject)
public class VocabularyEntryObject: NSManagedObject {

    /// CloudKit requires `id` to be optional in the model; we assign a UUID at insertion time
    /// so callers can rely on it being non-nil for the lifetime of the row.
    public override func awakeFromInsert() {
        super.awakeFromInsert()
        if id == nil {
            id = UUID()
        }
    }

    /// Composite identifier for use as a dictionary key or Hashable identity.
    struct Identifier: Hashable {
        let language: String
        let lemma: String
    }

    var identifier: Identifier {
        Identifier(language: language, lemma: lemma)
    }

    /// Returns true if the raw string looks like a multi-word phrase: contains
    /// internal whitespace between two letter runs (after trimming edges).
    static func looksLikePhrase(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return false }
        let scalars = Array(trimmed.unicodeScalars)
        for i in 1 ..< (scalars.count - 1) where CharacterSet.whitespaces.contains(scalars[i]) {
            let leftIsLetter = CharacterSet.letters.contains(scalars[i - 1])
            let rightIsLetter = CharacterSet.letters.contains(scalars[i + 1])
            if leftIsLetter && rightIsLetter { return true }
        }
        return false
    }

    /// Collapses internal whitespace runs to single spaces and trims edges.
    static func collapseWhitespace(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// Returns the largest "word-shaped" segment of `raw`, preserving case.
    /// Splits on any character that is not a letter, digit, apostrophe, or hyphen,
    /// keeps the longest remaining segment, and trims edge apostrophes/hyphens.
    /// Used for the visible surface form on a vocab entry — strips OCR/stutter
    /// junk like "NEIN..!" → "NEIN" while keeping "auto-mobile", "it's" intact.
    /// Returns an empty string if `raw` contains no usable letter/digit run.
    ///
    /// For multi-word phrases (whitespace between letter runs), preserves
    /// whitespace and applies the per-token cleanup individually so
    /// "Kick the Bucket..!" → "Kick the Bucket".
    static func cleanSurfaceForm(_ raw: String) -> String {
        if looksLikePhrase(raw) {
            let collapsed = collapseWhitespace(raw)
            let cleanedTokens = collapsed
                .split(separator: " ")
                .map { cleanSingleSegment(String($0)) }
                .filter { !$0.isEmpty }
            return cleanedTokens.joined(separator: " ")
        }
        return cleanSingleSegment(raw)
    }

    private static func cleanSingleSegment(_ raw: String) -> String {
        let inWord: Set<Unicode.Scalar> = ["'", "\u{2019}", "-"]
        var segments: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            let isWordChar = CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
                || inWord.contains(scalar)
            if isWordChar {
                current.append(scalar)
            } else if !current.isEmpty {
                segments.append(String(current))
                current.removeAll()
            }
        }
        if !current.isEmpty { segments.append(String(current)) }
        guard let longest = segments.max(by: { $0.unicodeScalars.count < $1.unicodeScalars.count }) else {
            return ""
        }
        let edgeChars = CharacterSet(charactersIn: "'\u{2019}-")
        return longest.trimmingCharacters(in: edgeChars)
    }

    /// Normalises a lemma for storage: same split/longest-segment rule as
    /// `cleanSurfaceForm` but lowercased. Used as the row's primary lookup key
    /// (case-insensitive identity). Multi-word phrases preserve whitespace.
    static func normalize(_ lemma: String) -> String {
        cleanSurfaceForm(lemma).lowercased()
    }

    /// True for entries that store a multi-word expression. Belt-and-suspenders
    /// check: trusts either the explicit `kind` raw value or the lemma's shape.
    public var isPhrase: Bool {
        if let k = kind, !k.isEmpty { return true }
        return lemma.contains(" ")
    }

    /// Upserts fields from caller-supplied values. Does NOT save the context.
    func load(
        language: String,
        lemma: String,
        surfaceForm: String,
        translation: String?,
        sourceMangaId: String?,
        sourceMangaSourceId: String?,
        kind: String? = nil
    ) {
        self.language = language
        self.lemma = lemma
        self.surfaceForm = surfaceForm
        self.translation = translation
        self.sourceMangaId = sourceMangaId
        self.sourceMangaSourceId = sourceMangaSourceId
        self.dateLastSeen = Date()
        if let kind {
            self.kind = kind
        }
    }
}

extension VocabularyEntryObject {

    @nonobjc public class func fetchRequest() -> NSFetchRequest<VocabularyEntryObject> {
        NSFetchRequest<VocabularyEntryObject>(entityName: "VocabularyEntry")
    }

    @NSManaged public var id: UUID?
    @NSManaged public var lemma: String
    @NSManaged public var surfaceForm: String
    @NSManaged public var language: String
    @NSManaged public var translation: String?
    @NSManaged public var dateAdded: Date
    @NSManaged public var dateLastSeen: Date
    @NSManaged public var sourceMangaId: String?
    @NSManaged public var sourceMangaSourceId: String?
    @NSManaged public var notes: String?
    /// Raw value of `PhraseKind` for multi-word-expression entries; nil for single words.
    @NSManaged public var kind: String?

    @NSManaged public var progress: FamiliarityProgressObject?
    @NSManaged public var flashcardState: FlashcardStateObject?
}
