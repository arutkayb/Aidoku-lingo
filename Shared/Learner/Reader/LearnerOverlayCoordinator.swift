//
//  LearnerOverlayCoordinator.swift
//  Aidoku
//
//  @MainActor singleton that manages per-page LearnerOverlayViews.
//  Called from ReaderPageView after image assignment and from ReaderPagedViewController
//  on page-change events.
//

#if canImport(UIKit)
import UIKit

/// Key uniquely identifying one reader page.
private struct PageKey: Hashable {
    let sourceId: String
    let mangaId: String
    let chapterId: String
    let pageIndex: Int

    init(_ ctx: LearnerPageContext) {
        sourceId = ctx.sourceId
        mangaId = ctx.mangaId
        chapterId = ctx.chapterId
        pageIndex = ctx.pageIndex
    }
}

/// Tracks overlay state for a single page.
private struct PageState {
    weak var overlay: LearnerOverlayView?
    weak var pageView: ReaderPageView?
    var lastOCRResult: OCRResult?
}

@MainActor
final class LearnerOverlayCoordinator {

    static let shared = LearnerOverlayCoordinator()

    private init() {}

    private let ocrCache = OCRResultCache()
    private lazy var ocr: OCRService = VisionOCRService(cache: ocrCache)
    private var pageStates: [PageKey: PageState] = [:]

    // MARK: — Public API

    /// Call this from ReaderPageView after `imageView.image = image`.
    func imageDidLoad(_ image: UIImage, context: LearnerPageContext, container: ReaderPageView) {
        let mangaId = context.mangaId
        guard isLearnerEnabled(for: mangaId) else {
            deactivate(for: context, container: container)
            return
        }

        let key = PageKey(context)

        // If an overlay already exists from a prior load (same page), reuse it.
        let existingOverlay = pageStates[key]?.overlay

        Task {
            guard image.cgImage != nil else { return }

            let languages = ocrLanguages()
            let result: OCRResult
            do {
                result = try await ocr.recognize(image: image, languages: languages)
            } catch {
                return
            }

            // Attach (or reuse) overlay
            let overlay: LearnerOverlayView
            if let existing = existingOverlay, existing.superview != nil {
                overlay = existing
            } else {
                overlay = LearnerOverlayView()
                overlay.translatesAutoresizingMaskIntoConstraints = false
                container.imageView.addSubview(overlay)
                NSLayoutConstraint.activate([
                    overlay.topAnchor.constraint(equalTo: container.imageView.topAnchor),
                    overlay.leadingAnchor.constraint(equalTo: container.imageView.leadingAnchor),
                    overlay.trailingAnchor.constraint(equalTo: container.imageView.trailingAnchor),
                    overlay.bottomAnchor.constraint(equalTo: container.imageView.bottomAnchor)
                ])
            }

            overlay.update(
                words: result.words,
                vocabIndex: .shared,
                language: languages.first ?? "de-DE",
                pageContext: context
            )

            pageStates[key] = PageState(
                overlay: overlay,
                pageView: container,
                lastOCRResult: result
            )
        }
    }

    /// Call this when a page becomes visible after a swipe (to refresh badges).
    func pageDidBecomeVisible(context: LearnerPageContext, container: ReaderPageView) {
        guard isLearnerEnabled(for: context.mangaId) else { return }
        let key = PageKey(context)
        guard let state = pageStates[key], let overlay = state.overlay, let result = state.lastOCRResult else {
            // No cached result; trigger a fresh OCR if image is available
            if let image = container.imageView.image {
                imageDidLoad(image, context: context, container: container)
            }
            return
        }
        // Refresh badges with updated vocab index
        overlay.update(
            words: result.words,
            vocabIndex: .shared,
            language: ocrLanguages().first ?? "de-DE",
            pageContext: context
        )
    }

    /// Removes overlay for a page (called when Learner is toggled off).
    func deactivate(for context: LearnerPageContext, container: ReaderPageView) {
        let key = PageKey(context)
        if let state = pageStates[key] {
            state.overlay?.removeFromSuperview()
            pageStates.removeValue(forKey: key)
        }
    }

    /// Returns the most recent OCR result for a page, or nil if not yet computed.
    func ocrResult(for context: LearnerPageContext) -> OCRResult? {
        pageStates[PageKey(context)]?.lastOCRResult
    }

    /// Invalidates the OCR cache for a page and re-runs OCR, refreshing the overlay.
    /// Called from the reader's Re-OCR menu item. (Task 6)
    func reOCR(for context: LearnerPageContext, container: ReaderPageView) {
        let key = PageKey(context)
        // Evict the cached result so `imageDidLoad` is forced to re-run Vision.
        if let image = container.imageView.image, let pngData = image.pngData() {
            ocrCache.invalidate(imageData: pngData, languages: ocrLanguages())
        }
        pageStates[key]?.lastOCRResult = nil
        // Re-run the full OCR + overlay pipeline.
        if let image = container.imageView.image {
            imageDidLoad(image, context: context, container: container)
        }
    }

    /// Called when the zoom scale of a page's scroll view changes.
    /// Rebuilds the overlay so word-region frames stay aligned with the zoomed image. (Task 2)
    func zoomChanged(for context: LearnerPageContext, container: ReaderPageView) {
        pageStates[PageKey(context)]?.overlay?.setNeedsRebuild()
    }

    /// Called when the global Learner toggle changes for a manga.
    func setEnabled(_ enabled: Bool, for mangaId: String) {
        if !enabled {
            // Remove all overlays for this manga
            let keysToRemove = pageStates.keys.filter { $0.mangaId == mangaId }
            for key in keysToRemove {
                pageStates[key]?.overlay?.removeFromSuperview()
                pageStates.removeValue(forKey: key)
            }
        }
        // If enabling, the next imageDidLoad call from the page view controller will attach overlays
    }

    // MARK: — Helpers

    private func isLearnerEnabled(for mangaId: String) -> Bool {
        // Migration + tri-state gate (Task 1).
        let enabled = LearnerGate.isEnabled(mangaId: mangaId)
        if enabled && !UserDefaults.standard.bool(forKey: "Learner.enabledGlobally") {
            // First time Learner is active — flip the visibility flag so the
            // Vocabulary tab becomes visible (plan Task 8 Decision #2).
            UserDefaults.standard.set(true, forKey: "Learner.enabledGlobally")
            NotificationCenter.default.post(name: .learnerEnabledGloballyChanged, object: nil)
        }
        return enabled
    }

    /// Returns the list of OCR recognition languages to use.
    /// On first call after an upgrade from the old single-select UI, migrates
    /// `Learner.ocrLanguages` (String) → `Learner.ocrLanguagesList` ([String] JSON).
    /// Defaults to `["de-DE"]` when no setting is present.
    func ocrLanguages() -> [String] {
        let newKey = "Learner.ocrLanguagesList"
        let legacyKey = "Learner.ocrLanguages"

        // One-shot migration: if the new key is absent and the old String key is present,
        // copy the old value into the new JSON-encoded array key.
        if UserDefaults.standard.data(forKey: newKey) == nil,
           let oldLang = UserDefaults.standard.string(forKey: legacyKey), !oldLang.isEmpty {
            if let data = try? JSONEncoder().encode([oldLang]) {
                UserDefaults.standard.set(data, forKey: newKey)
            }
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }

        if let data = UserDefaults.standard.data(forKey: newKey),
           let langs = try? JSONDecoder().decode([String].self, from: data), !langs.isEmpty {
            let allowed = LearnerOCRLanguagesPicker.allowedOCRCodes
            let filtered = langs.filter { allowed.contains($0) }
            if filtered.isEmpty {
                if let rewriteData = try? JSONEncoder().encode(["de-DE"]) {
                    UserDefaults.standard.set(rewriteData, forKey: newKey)
                }
                return ["de-DE"]
            }
            if filtered.count != langs.count,
               let rewriteData = try? JSONEncoder().encode(filtered) {
                UserDefaults.standard.set(rewriteData, forKey: newKey)
            }
            return filtered
        }
        return ["de-DE"]
    }

}
#endif // canImport(UIKit)
