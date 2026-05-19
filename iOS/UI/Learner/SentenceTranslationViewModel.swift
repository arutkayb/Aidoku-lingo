//
//  SentenceTranslationViewModel.swift
//  Aidoku (iOS)
//
//  ObservableObject view model for SentenceTranslationSheet.
//  Groups OCR fragments into sentences, translates them in parallel,
//  and provides on-demand CEFR simplification.
//

import Foundation
#if canImport(Translation)
import Translation
#endif
import Combine

// MARK: — SentenceVM

/// View-level representation of one translated sentence.
struct SentenceVM: Identifiable {
    let id: UUID = UUID()
    /// Source-language sentence text.
    let source: String
    /// Populated as each parallel translation arrives.
    var translation: String?
    /// Populated lazily when the user expands the simplification row.
    var simplified: String?
    /// Whether the simplification disclosure row is expanded.
    var simplifyExpanded: Bool = false
    /// Set if simplification failed.
    var simplifyError: String?
}

// MARK: — SentenceTranslationViewModel

@MainActor
final class SentenceTranslationViewModel: ObservableObject {

    // MARK: — Inputs

    let context: LearnerPageContext
    let ocrResult: OCRResult
    /// If non-nil, scroll to (or highlight) the sentence containing this lemma.
    let focusLemma: String?

    // MARK: — State

    @Published var sentences: [SentenceVM] = []
    @Published var isLoading: Bool = true
    @Published var loadError: TranslationError?

    // MARK: — Init

    init(context: LearnerPageContext, ocrResult: OCRResult, focusLemma: String? = nil) {
        self.context = context
        self.ocrResult = ocrResult
        self.focusLemma = focusLemma
    }

    // MARK: — Load

    /// Groups OCR lines into sentences and translates each via the composite service.
    /// Use this on pre-iOS-18 where Apple Translation is unavailable.
    func load() async {
        await loadSourceSentences()
        await translateAllViaService()
    }

    /// Step 1 only: groups fragments and populates `sentences` with source text.
    func loadSourceSentences() async {
        isLoading = true
        loadError = nil
        sentences = []

        let fragments = ocrResult.lines.enumerated().map { idx, line in
            TextFragment(text: line.text, index: idx)
        }

        guard !fragments.isEmpty else {
            isLoading = false
            return
        }

        let service = TranslationServiceFactory.shared
        let sourceLanguage = context.language

        // Step 1: group fragments into sentences. Failure isn't fatal — we fall back to
        // one-per-line below so Apple Translation can still run when Foundation Models
        // (used for grouping) is unavailable.
        var groups: [SentenceGroup] = []
        do {
            groups = try await service.groupFragmentsIntoSentences(fragments, language: sourceLanguage)
        } catch {
            print("[Learner] sentence grouping unavailable, falling back to one-per-line: \(error)")
        }

        // Validate that every input fragment index appears exactly once across groups.
        // If the LLM dropped or duplicated indices, fall back to one-fragment-per-sentence.
        let inputIndices = Set(fragments.map(\.index))
        let returnedFlat = groups.flatMap(\.fragmentIndices)
        let returnedSet = Set(returnedFlat)
        let groupingIsValid = !groups.isEmpty
            && returnedSet == inputIndices
            && returnedFlat.count == inputIndices.count
        let resolvedGroups: [SentenceGroup]
        if groupingIsValid {
            resolvedGroups = groups
        } else {
            if !groups.isEmpty {
                print("[Learner] sentence grouping returned invalid fragment indices; falling back to bubble-adjacency heuristic")
            }
            // Use bounding-box adjacency to group lines belonging to the same speech bubble.
            resolvedGroups = SentenceTranslationViewModel.bubbleGroupedFallback(from: ocrResult.lines)
        }

        // Seed sentences array with source text (no translation yet)
        sentences = resolvedGroups.map { SentenceVM(source: $0.combinedText) }
        isLoading = false
    }

    /// Step 2: translates each sentence concurrently via the composite service.
    /// Used on pre-iOS-18 where Apple Translation is unavailable.
    private func translateAllViaService() async {
        let service = TranslationServiceFactory.shared
        let sourceLanguage = context.language
        let targetLanguage = UserDefaults.standard.string(forKey: "Learner.targetLanguage") ?? "en"

        await withTaskGroup(of: (Int, String?).self) { group in
            for (idx, sentence) in sentences.enumerated() {
                let text = sentence.source
                group.addTask {
                    let result = try? await service.translateSentence(
                        text,
                        sourceLanguage: sourceLanguage,
                        targetLanguage: targetLanguage
                    )
                    return (idx, result?.translation)
                }
            }
            for await (idx, translation) in group {
                if idx < sentences.count {
                    sentences[idx].translation = translation
                }
            }
        }
    }

    #if canImport(Translation)
    /// Step 2 using Apple's Translation framework session. Sentences are translated
    /// sequentially because TranslationSession serialises requests internally.
    @available(iOS 18.0, *)
    func translateAll(using session: TranslationSession) async {
        for idx in sentences.indices {
            let text = sentences[idx].source
            do {
                let response = try await session.translate(text)
                if idx < sentences.count {
                    sentences[idx].translation = response.targetText
                }
            } catch {
                print("[Learner] Apple Translation sentence failed: \(error)")
            }
        }
    }
    #endif

    // MARK: — Retry

    func retry() async {
        await load()
    }

    // MARK: — Simplify (lazy, on row expand)

    func simplify(id: UUID) async {
        guard let idx = sentences.firstIndex(where: { $0.id == id }) else { return }
        guard sentences[idx].simplified == nil else { return }

        let service = TranslationServiceFactory.shared
        let sourceLanguage = context.language
        let rawLevel = UserDefaults.standard.string(forKey: "Learner.simplificationLevel") ?? "A2"
        let level = CEFRLevel(rawValue: rawLevel) ?? .a2
        let text = sentences[idx].source

        do {
            let simplified = try await service.simplifyToCEFR(text, level: level, language: sourceLanguage)
            sentences[idx].simplified = simplified
            sentences[idx].simplifyError = nil
        } catch {
            sentences[idx].simplifyError = "LEARNER_SENTENCE_LOAD_ERROR".localized
        }
    }
}

// MARK: — Bubble-adjacency fallback grouping

extension SentenceTranslationViewModel {

    /// Groups OCR lines into sentence fragments using a bounding-box adjacency heuristic.
    /// Two consecutive lines are considered part of the same speech bubble when:
    ///   - The vertical distance between their centres ≤ 1.5 × average line height, AND
    ///   - Their horizontal ranges overlap by ≥ 50% of the narrower line's width.
    ///
    /// Vision bounding boxes are in normalised coordinates (origin = bottom-left).
    /// The algorithm is purely geometric so it works without the LLM service.
    ///
    /// Marked `internal` so `SentenceTranslationViewModelTests` can call it directly.
    static func bubbleGroupedFallback(from lines: [OCRLineBox]) -> [SentenceGroup] {
        guard !lines.isEmpty else { return [] }

        // Thresholds — conservative to err on the side of more (smaller) groups.
        let verticalFactor: CGFloat = 1.5
        let horizontalOverlapFactor: CGFloat = 0.5

        let avgHeight = lines.map(\.boundingBox.height).reduce(0, +) / CGFloat(lines.count)

        var groups: [[Int]] = []   // each element = list of line indices in one group
        var currentGroup: [Int] = [0]

        for i in 1 ..< lines.count {
            let prev = lines[i - 1].boundingBox
            let curr = lines[i].boundingBox

            // Vertical centre distance (Vision uses bottom-left origin, so centre.y = minY + height/2)
            let prevCentreY = prev.minY + prev.height / 2
            let currCentreY = curr.minY + curr.height / 2
            let vertDist = abs(prevCentreY - currCentreY)

            // Horizontal overlap
            let overlapLeft = max(prev.minX, curr.minX)
            let overlapRight = min(prev.maxX, curr.maxX)
            let overlap = max(0, overlapRight - overlapLeft)
            let minWidth = min(prev.width, curr.width)
            let hOverlapRatio = minWidth > 0 ? overlap / minWidth : 0

            let sameBubble = vertDist <= verticalFactor * avgHeight
                && hOverlapRatio >= horizontalOverlapFactor

            if sameBubble {
                currentGroup.append(i)
            } else {
                groups.append(currentGroup)
                currentGroup = [i]
            }
        }
        groups.append(currentGroup)

        // Convert index groups → SentenceGroup values.
        // Fragment indices map 1-to-1 with line indices so we reuse them directly.
        return groups.enumerated().map { _, indices in
            let text = indices.map { lines[$0].text }.joined(separator: " ")
            return SentenceGroup(fragmentIndices: indices, combinedText: text)
        }
    }
}

// MARK: — LearnerPageContext language helper

extension LearnerPageContext {
    /// Derives the source language tag from the OCR language stored in UserDefaults.
    /// Currently global; per-manga language is tracked as I11 in the review backlog.
    var language: String {
        // Prefer the new multi-select list (first entry = primary language).
        if let data = UserDefaults.standard.data(forKey: "Learner.ocrLanguagesList"),
           let langs = try? JSONDecoder().decode([String].self, from: data),
           let first = langs.first, !first.isEmpty {
            return first
        }
        // Legacy single-select key (kept as a fallback for users mid-migration).
        if let lang = UserDefaults.standard.string(forKey: "Learner.ocrLanguages"), !lang.isEmpty {
            return lang
        }
        return "de-DE"
    }
}

// MARK: — Localization

private extension String {
    var localized: String { NSLocalizedString(self, comment: "") }
}
