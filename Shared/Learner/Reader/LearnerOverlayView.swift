//
//  LearnerOverlayView.swift
//  Aidoku
//
//  UIView subclass rendering invisible tappable word regions + familiarity badges
//  over a reader page image.
//
//  Coordinate transform:
//    Vision uses bottom-left origin, normalized [0…1].
//    UIKit uses top-left origin.
//    Transform: viewY = (1 - visionY - visionHeight) * viewHeight
//

#if canImport(UIKit)
import UIKit

/// A transparent view placed as a sibling over ReaderPageView.imageView.
/// Handles:
///  - Per-word tappable UIControl regions
///  - Familiarity badge CAShapeLayer dots on known words
///  - Hit-test passthrough for empty space (chrome-toggle still works)
final class LearnerOverlayView: UIView {

    // MARK: — State

    private var pageContext: LearnerPageContext?
    private var wordBoxes: [OCRWordBox] = []
    private var phrases: [OCRPhrase] = []
    private var wordIndexToPhrase: [Int: OCRPhrase] = [:]
    private var vocabIndex: VocabIndex = .shared
    private var language: String = "de-DE"

    // MARK: — Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        // Note: long-press recognizer removed (Task 3). Sentence translation is
        // triggered from WordLookupSheet's "Translate sentence" button only.
        // This allows VisionKit Live Text to coexist without gesture conflicts.
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: — Public API

    /// Updates the overlay with a fresh OCR result and vocab index snapshot.
    func update(
        words: [OCRWordBox],
        phrases: [OCRPhrase] = [],
        vocabIndex: VocabIndex,
        language: String,
        pageContext: LearnerPageContext
    ) {
        self.wordBoxes = words
        self.phrases = phrases
        self.wordIndexToPhrase = Self.buildPhraseLookup(phrases)
        self.vocabIndex = vocabIndex
        self.language = language
        self.pageContext = pageContext
        rebuild()
    }

    /// Removes all word regions and badges.
    func clear() {
        wordBoxes = []
        phrases = []
        wordIndexToPhrase = [:]
        pageContext = nil
        rebuild()
    }

    /// Builds the wordIndex → OCRPhrase lookup map. If multiple phrases claim the same
    /// index (defensive: Task 2's overlap resolution should prevent this), the phrase
    /// whose `wordIndices.first` is smallest wins.
    static func buildPhraseLookup(_ phrases: [OCRPhrase]) -> [Int: OCRPhrase] {
        var map: [Int: OCRPhrase] = [:]
        for phrase in phrases {
            guard let leftmost = phrase.wordIndices.first else { continue }
            for index in phrase.wordIndices {
                if let existing = map[index] {
                    guard let existingLeftmost = existing.wordIndices.first else { continue }
                    if leftmost < existingLeftmost {
                        map[index] = phrase
                    } else if leftmost == existingLeftmost {
                        LogManager.logger.warn(
                            "LearnerOverlayView: word index \(index) matched by two phrases with identical leftmost"
                        )
                    }
                } else {
                    map[index] = phrase
                }
            }
        }
        return map
    }

    /// Triggers an immediate rebuild of word regions after a zoom-scale change.
    /// Called by LearnerOverlayCoordinator.zoomChanged(for:container:). (Task 2)
    func setNeedsRebuild() {
        rebuild()
    }

    // MARK: — Hit-testing

    /// Passes touches through to the underlying imageView when they don't land on a
    /// WordRegionControl. Without this, the overlay covers the entire image rect and
    /// swallows taps on Live Text's supplementary button + the reader's chrome-toggle.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        if hit === self { return nil }
        return hit
    }

    // MARK: — Layout

    private var lastRebuildBounds: CGRect = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        // First OCR pass often runs before Auto Layout has sized the overlay; rebuild
        // when bounds become non-zero so word regions and badges land in the right place.
        if bounds.size != lastRebuildBounds.size, bounds.width > 0, bounds.height > 0 {
            lastRebuildBounds = bounds
            rebuild()
        }
    }

    // MARK: — Build regions

    private func rebuild() {
        // Remove old regions
        subviews.forEach { $0.removeFromSuperview() }
        layer.sublayers?.filter { $0 is CAShapeLayer }.forEach { $0.removeFromSuperlayer() }

        guard !wordBoxes.isEmpty, bounds.width > 0, bounds.height > 0 else { return }

        let viewSize = bounds.size

        // Phrase underlines render beneath the word tap targets (added to layer first).
        for phrase in phrases {
            let frame = visionToView(phrase.boundingBox, in: viewSize)
            guard frame.width > 2, frame.height > 2 else { continue }
            let underline = CAShapeLayer()
            let underlineRect = CGRect(
                x: frame.minX,
                y: frame.maxY - 2,
                width: frame.width,
                height: 2
            )
            underline.path = UIBezierPath(rect: underlineRect).cgPath
            underline.fillColor = UIColor.systemTeal.withAlphaComponent(0.55).cgColor
            layer.addSublayer(underline)
        }

        for (index, box) in wordBoxes.enumerated() {
            let frame = visionToView(box.boundingBox, in: viewSize)
            guard frame.width > 2, frame.height > 2 else { continue }

            // Tappable word region
            let control = WordRegionControl(wordBox: box, wordIndex: index)
            control.frame = frame
            control.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.25)
            control.layer.cornerRadius = 2
            control.layer.borderWidth = 0.5
            control.layer.borderColor = UIColor.systemYellow.withAlphaComponent(0.5).cgColor
            control.addTarget(self, action: #selector(wordTapped(_:)), for: .touchUpInside)
            control.accessibilityLabel = box.text
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(wordLongPressed(_:)))
            longPress.minimumPressDuration = 0.5
            control.addGestureRecognizer(longPress)
            addSubview(control)

            // Familiarity badge
            let lemma = VocabularyEntryObject.normalize(box.text)
            let identifier = VocabularyEntryObject.Identifier(language: language, lemma: lemma)
            if let level = vocabIndex.level(for: identifier) {
                let done = vocabIndex.isDone(for: identifier)
                addBadge(to: frame, level: level, done: done)
            }
        }
    }

    // MARK: — Word tap

    @objc private func wordTapped(_ sender: WordRegionControl) {
        guard let pageContext else { return }
        let box = sender.wordBox
        if let phrase = wordIndexToPhrase[sender.wordIndex] {
            let event = PhraseTapEvent(phrase: phrase, language: language, pageContext: pageContext)
            Task { @MainActor in
                LearnerEvents.shared.phraseTapped.send(event)
            }
            return
        }
        sendWordTapEvent(for: box, pageContext: pageContext)
    }

    @objc private func wordLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              let control = recognizer.view as? WordRegionControl,
              let pageContext else { return }
        sendWordTapEvent(for: control.wordBox, pageContext: pageContext)
    }

    private func sendWordTapEvent(for box: OCRWordBox, pageContext: LearnerPageContext) {
        let lemma = VocabularyEntryObject.normalize(box.text)
        let event = WordTapEvent(
            surfaceForm: box.text,
            lemma: lemma,
            language: language,
            pageContext: pageContext
        )
        Task { @MainActor in
            LearnerEvents.shared.wordTapped.send(event)
        }
    }

    // MARK: — Badge

    private func addBadge(to frame: CGRect, level: FamiliarityLevel, done: Bool) {
        let badgeSize: CGFloat = 8
        let badgeOrigin = CGPoint(
            x: frame.maxX - badgeSize - 1,
            y: frame.maxY - badgeSize - 1
        )
        let badgeRect = CGRect(origin: badgeOrigin, size: CGSize(width: badgeSize, height: badgeSize))

        let badgeLayer = CAShapeLayer()
        badgeLayer.path = UIBezierPath(ovalIn: badgeRect).cgPath
        badgeLayer.fillColor = badgeColor(for: level, done: done).cgColor
        badgeLayer.strokeColor = UIColor.black.withAlphaComponent(0.3).cgColor
        badgeLayer.lineWidth = 0.5
        layer.addSublayer(badgeLayer)
    }

    private func badgeColor(for level: FamiliarityLevel, done: Bool) -> UIColor {
        if done { return .systemGreen }
        switch level {
        case .fresh:    return .systemGray.withAlphaComponent(0.8)
        case .learning: return .systemYellow
        case .familiar: return .systemOrange
        case .mastered: return .systemGreen
        }
    }

    // MARK: — Coordinate transform

    /// Converts a Vision normalized bounding box (bottom-left origin, relative to the
    /// underlying image) to UIKit view coordinates inside the aspect-fit displayed rect.
    private func visionToView(_ box: CGRect, in size: CGSize) -> CGRect {
        let displayed = displayedImageRect(in: size)
        let x = displayed.origin.x + box.origin.x * displayed.width
        let y = displayed.origin.y + (1.0 - box.origin.y - box.height) * displayed.height
        let w = box.width * displayed.width
        let h = box.height * displayed.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Returns the rect (inside our overlay bounds) that the imageView's image actually fills.
    /// imageView uses `.scaleAspectFit` so the image is letterboxed when aspect ratios differ.
    private func displayedImageRect(in size: CGSize) -> CGRect {
        guard let imageSize = (superview as? UIImageView)?.image?.size,
              imageSize.width > 0, imageSize.height > 0,
              size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let imageAspect = imageSize.width / imageSize.height
        let viewAspect = size.width / size.height
        if imageAspect > viewAspect {
            // image is wider — fills width, letterboxed top/bottom
            let h = size.width / imageAspect
            let y = (size.height - h) / 2
            return CGRect(x: 0, y: y, width: size.width, height: h)
        } else {
            // image is taller — fills height, letterboxed left/right
            let w = size.height * imageAspect
            let x = (size.width - w) / 2
            return CGRect(x: x, y: 0, width: w, height: size.height)
        }
    }
}

// MARK: — WordRegionControl

/// UIControl subclass that holds a reference to its OCRWordBox for tap callbacks.
/// Internal (not private) so ReaderViewController can type-check touches for gesture-delegate
/// filtering without a back-reference to the overlay. (Task 2)
final class WordRegionControl: UIControl {
    let wordBox: OCRWordBox
    /// Absolute index into the OCRResult.words array; used to look up phrase membership.
    let wordIndex: Int

    init(wordBox: OCRWordBox, wordIndex: Int) {
        self.wordBox = wordBox
        self.wordIndex = wordIndex
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif // canImport(UIKit)
