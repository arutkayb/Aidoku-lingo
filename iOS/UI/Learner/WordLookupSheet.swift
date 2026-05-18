//
//  WordLookupSheet.swift
//  Aidoku (iOS)
//
//  Bottom sheet shown when the user taps a recognized word in the reader.
//  Displays translation, familiarity picker, and vocab management controls.
//

import SwiftUI
#if canImport(Translation)
import Translation
#endif

struct WordLookupSheet: View {

    @StateObject private var viewModel: WordLookupViewModel
    private let wordTapEvent: WordTapEvent?
    private let vocabOnly: Bool
    @State private var isEditing: Bool = false

    // Init from a reader word-tap event
    init(event: WordTapEvent) {
        self._viewModel = StateObject(wrappedValue: WordLookupViewModel(event: event))
        self.wordTapEvent = event
        self.vocabOnly = false
    }

    // Init from a reader phrase-tap event. The view triggers `lookup(phrase:...)`
    // on appear so the same translation pipeline runs.
    init(phraseEvent: PhraseTapEvent) {
        self._viewModel = StateObject(wrappedValue: WordLookupViewModel(phraseEvent: phraseEvent))
        self.wordTapEvent = nil
        self.vocabOnly = false
    }

    // Init for vocab-list mode (no sentence translation button)
    init(entry: VocabularyEntryObject, vocabOnly: Bool = true) {
        self._viewModel = StateObject(wrappedValue: WordLookupViewModel(entry: entry))
        self.wordTapEvent = nil
        self.vocabOnly = vocabOnly
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {

                    // MARK: — Word header
                    VStack(alignment: .leading, spacing: 4) {
                        if let kind = viewModel.phraseKind {
                            Text(kind.displayName)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundColor(.accentColor)
                                .clipShape(Capsule())
                        }
                        if isEditing {
                            // The lemma (lookup key) stays immutable, so it's shown read-only
                            // above the editable surface-form field for context.
                            Text(viewModel.lemma)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("LEARNER_EDIT_WORD_PLACEHOLDER".localized,
                                      text: $viewModel.editableSurfaceForm)
                                .font(.title2.bold())
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Text(viewModel.surfaceForm)
                                .font(.largeTitle.bold())

                            if viewModel.lemma != viewModel.surfaceForm.lowercased() {
                                Text(viewModel.lemma)
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Divider()

                    // MARK: — Translation
                    if isEditing {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("LEARNER_EDIT_TRANSLATION_LABEL".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("LEARNER_EDIT_TRANSLATION_PLACEHOLDER".localized,
                                      text: $viewModel.editableTranslation)
                                .textFieldStyle(.roundedBorder)
                        }
                    } else if viewModel.isLoading {
                        HStack {
                            ProgressView()
                            Text("LOADING_ELLIPSIS".localized)
                                .foregroundColor(.secondary)
                        }
                    } else if let error = viewModel.loadError {
                        Text(errorMessage(for: error))
                            .foregroundColor(.red)
                            .font(.body)
                    } else if let t = viewModel.translation {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t.translation)
                                .font(.title3)

                            if let pos = t.partOfSpeech {
                                Text(pos)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            if let example = t.exampleSentence, !example.isEmpty {
                                Text("\"\(example)\"")
                                    .font(.body)
                                    .italic()
                                    .foregroundColor(.secondary)
                                    .padding(.top, 4)
                            }
                        }
                    }

                    // MARK: — Notes (vocab-only mode)
                    if vocabOnly && viewModel.isInVocab {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("LEARNER_NOTES_LABEL".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            if isEditing {
                                TextEditor(text: $viewModel.editableNotes)
                                    .frame(minHeight: 80)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                    )
                            } else if !viewModel.editableNotes.isEmpty {
                                Text(viewModel.editableNotes)
                                    .font(.body)
                                    .foregroundColor(.primary)
                            } else {
                                Text("LEARNER_NOTES_EMPTY".localized)
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .italic()
                            }
                        }
                    }

                    Divider()

                    // MARK: — Familiarity picker (if in vocab)
                    if viewModel.isInVocab {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("LEARNER_VOCAB_FAMILIARITY_LEVEL".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack(spacing: 12) {
                                ForEach(0..<4) { level in
                                    Button {
                                        Task { await viewModel.setFamiliarity(Int16(level)) }
                                    } label: {
                                        Circle()
                                            .fill(level <= Int(viewModel.familiarity)
                                                  ? familiarityColor(Int16(level))
                                                  : Color.gray.opacity(0.3))
                                            .frame(width: 24, height: 24)
                                            .overlay(
                                                Circle()
                                                    .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(viewModel.isDone)
                                }
                                Spacer()
                            }
                        }
                    }

                    // MARK: — Vocab toggle button
                    Button {
                        Task { await viewModel.toggleVocab() }
                    } label: {
                        Label(
                            viewModel.isInVocab
                                ? "LEARNER_IN_VOCAB".localized
                                : "LEARNER_ADD_TO_VOCAB".localized,
                            systemImage: viewModel.isInVocab ? "checkmark.circle.fill" : "plus.circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(viewModel.isInVocab ? .green : .accentColor)

                    // MARK: — Mark Done (only if in vocab and not done)
                    if viewModel.isInVocab && !viewModel.isDone {
                        Button {
                            Task { await viewModel.markDone() }
                        } label: {
                            Label("LEARNER_MARK_DONE".localized, systemImage: "lock.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                    }

                    // MARK: — Translate sentence (hidden in vocab-only mode)
                    if !vocabOnly, let event = wordTapEvent {
                        Button {
                            viewModel.requestSentenceTranslation(event: event)
                        } label: {
                            Label("LEARNER_TRANSLATE_SENTENCE".localized, systemImage: "text.bubble")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer(minLength: 20)
                }
                .padding()
            }
            .navigationTitle("LEARNER_WORD_LOOKUP".localized)
            .navigationBarTitleDisplayMode(.inline)
            // Toolbar items use inner `if` (regular ViewBuilder, iOS 13+) rather
            // than `if/else` at the ToolbarContent level — that builder's `buildIf`/
            // `buildEither` are only iOS 16+. Each ToolbarItem is declared once.
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if vocabOnly && viewModel.isInVocab && isEditing {
                        Button("CANCEL".localized) {
                            viewModel.revertEdits()
                            isEditing = false
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if vocabOnly && viewModel.isInVocab {
                        if isEditing {
                            Button("SAVE".localized) {
                                Task {
                                    await viewModel.applyEdits()
                                    isEditing = false
                                }
                            }
                            .font(.body.weight(.semibold))
                        } else {
                            Button("EDIT".localized) {
                                isEditing = true
                            }
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .modifier(WordLookupTranslationDriver(viewModel: viewModel))
    }

    // MARK: — Helpers

    private func familiarityColor(_ level: Int16) -> Color {
        switch level {
        case 0: return .gray
        case 1: return .yellow
        case 2: return .orange
        case 3: return .green
        default: return .gray
        }
    }

    private func errorMessage(for error: TranslationError) -> String {
        switch error {
        case .unavailable:
            return "LEARNER_TRANSLATION_UNAVAILABLE".localized
        case .networkError:
            return "LEARNER_TRANSLATION_NETWORK_ERROR".localized
        case .invalidKey:
            return "LEARNER_TRANSLATION_INVALID_KEY".localized
        default:
            return "LEARNER_TRANSLATION_NETWORK_ERROR".localized
        }
    }
}

// MARK: — String localization helper

private extension String {
    var localized: String { NSLocalizedString(self, comment: "") }
}

// MARK: — Translation driver

/// Routes translation through Apple's Translation framework on iOS 18+,
/// falling back to the composite TranslationService (DeepL → Foundation Models) below that.
private struct WordLookupTranslationDriver: ViewModifier {
    @ObservedObject var viewModel: WordLookupViewModel

    func body(content: Content) -> some View {
        #if canImport(Translation)
        if #available(iOS 18.0, *) {
            content.modifier(AppleTranslationModifier(viewModel: viewModel))
        } else {
            content.task { await viewModel.loadTranslation() }
        }
        #else
        content.task { await viewModel.loadTranslation() }
        #endif
    }
}

#if canImport(Translation)
@available(iOS 18.0, *)
private struct AppleTranslationModifier: ViewModifier {
    @ObservedObject var viewModel: WordLookupViewModel
    @State private var configuration: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .task {
                guard configuration == nil else { return }
                let target = UserDefaults.standard.string(forKey: "Learner.targetLanguage") ?? "en"
                let sourceCode = String(viewModel.language.prefix(2))
                configuration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: sourceCode),
                    target: Locale.Language(identifier: target)
                )
            }
            .translationTask(configuration) { session in
                await viewModel.loadTranslation(using: session)
            }
    }
}
#endif
