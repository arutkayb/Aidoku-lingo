//
//  LearnerOCRLanguagesPicker.swift
//  Aidoku (iOS)
//
//  SwiftUI multi-select picker for OCR recognition languages.
//  Reads/writes JSON-encoded [String] under the UserDefaults key
//  "Learner.ocrLanguagesList". (Task 7)
//

import SwiftUI

/// Five-row toggle list bound to the JSON-encoded OCR language list.
/// At least one language must remain selected (the last toggle is disabled
/// when it would remove the only remaining language).
struct LearnerOCRLanguagesPicker: View {

    // Available language codes and their display names (must stay in sync with
    // coordinator's default and ReaderSettingsView's old select list).
    // `internal` so tests can verify ordering behaviour.
    static let languages: [(code: String, display: String)] = [
        ("en-US", "English (en-US)"),
        ("de-DE", "German (de-DE)"),
        ("tr-TR", "Turkish (tr-TR)")
    ]

    static let defaultsKey = "Learner.ocrLanguagesList"

    @State private var selected: Set<String>

    init() {
        let loaded = Self.loadFromDefaults()
        _selected = State(initialValue: loaded)
    }

    var body: some View {
        ForEach(Self.languages, id: \.code) { lang in
            let isOn = selected.contains(lang.code)
            let isLast = selected.count == 1 && isOn
            Toggle(lang.display, isOn: Binding(
                get: { selected.contains(lang.code) },
                set: { newValue in
                    if newValue {
                        selected.insert(lang.code)
                    } else if selected.count > 1 {
                        selected.remove(lang.code)
                    }
                    // Always persist after change
                    Self.saveToDefaults(selected)
                }
            ))
            .disabled(isLast)  // prevent deselecting the last language
        }
        // Keep UI in sync if another view changes the defaults (e.g. after migration)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let fresh = Self.loadFromDefaults()
            if fresh != selected { selected = fresh }
        }
    }

    // MARK: — Persistence helpers
    // (internal access so unit tests can verify ordering and migration behaviour.)

    static func loadFromDefaults() -> Set<String> {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let langs = try? JSONDecoder().decode([String].self, from: data), !langs.isEmpty {
            return Set(langs)
        }
        return ["de-DE"]
    }

    static func saveToDefaults(_ langs: Set<String>) {
        guard !langs.isEmpty else { return }
        // Preserve the display order (Vision uses recognitionLanguages order as a
        // priority hint; alphabetical sort would drop that intent).
        let ordered = Self.languages.map(\.code).filter { langs.contains($0) }
        if let data = try? JSONEncoder().encode(ordered) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
