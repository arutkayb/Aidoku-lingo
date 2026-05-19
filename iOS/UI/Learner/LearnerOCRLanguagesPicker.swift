//
//  LearnerOCRLanguagesPicker.swift
//  Aidoku (iOS)
//
//  SwiftUI multi-select picker for OCR recognition languages.
//  Reads/writes JSON-encoded [String] under the UserDefaults key
//  "Learner.ocrLanguagesList".
//

import SwiftUI

/// Two-row toggle list bound to the JSON-encoded OCR language list.
/// At least one language must remain selected (the last toggle is disabled
/// when it would remove the only remaining language).
struct LearnerOCRLanguagesPicker: View {

    // `internal` so tests can verify ordering behaviour.
    static let languages: [(code: String, display: String)] = [
        ("de-DE", "German (de-DE)"),
        ("en-US", "English (en-US)")
    ]

    static let allowedOCRCodes: Set<String> = Set(languages.map(\.code))

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
            let filtered = Set(langs).intersection(allowedOCRCodes)
            if filtered.isEmpty {
                saveToDefaults(["de-DE"])
                return ["de-DE"]
            }
            if filtered.count != langs.count {
                saveToDefaults(filtered)
            }
            return filtered
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
