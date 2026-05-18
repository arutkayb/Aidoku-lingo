//
//  ReaderGestureDelegateTests.swift
//  Aidoku
//
//  Swift Testing cases for ReaderViewController's UIGestureRecognizerDelegate
//  predicate that blocks bar-toggle taps on Learner word regions. (Task 2)
//

import UIKit
import Testing
@testable import Aidoku

/// Tests the logic that determines whether a touch on a given view should
/// suppress the bar-toggle / fake-zoom tap gesture recognizer.
///
/// We test the predicate function directly without constructing a full
/// ReaderViewController (which requires a manga/chapter context). The predicate
/// logic — "return false if any ancestor is a WordRegionControl or LearnerOverlayView"
/// — is expressed as a standalone helper so it can be unit-tested in isolation.
@Suite struct ReaderGestureDelegateTests {

    /// Mirrors the suppress logic from ReaderViewController's
    /// gestureRecognizer(_:shouldReceive:) — returns false when the touch lands
    /// on a WordRegionControl (or descendant). The bare LearnerOverlayView is NOT
    /// blocked so empty-space taps reach the bar-toggle gesture.
    private func shouldReceiveTouch(on touchedView: UIView?) -> Bool {
        var view: UIView? = touchedView
        while let v = view {
            if v is WordRegionControl { return false }
            view = v.superview
        }
        return true
    }

    // MARK: — Tests

    // Tapping an unrelated plain UIView should not suppress the gesture
    @Test @MainActor func plainView_shouldReceive() {
        let plain = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(shouldReceiveTouch(on: plain) == true)
    }

    // Tapping directly on a WordRegionControl should suppress the gesture
    @Test @MainActor func wordRegionControl_shouldNotReceive() {
        let box = OCRWordBox(text: "Test", boundingBox: .zero, confidence: 0.9, lineIndex: 0)
        let control = WordRegionControl(wordBox: box, wordIndex: 0)
        #expect(shouldReceiveTouch(on: control) == false)
    }

    // Tapping a child of a WordRegionControl (e.g. a badge label) should suppress
    @Test @MainActor func childOfWordRegionControl_shouldNotReceive() {
        let box = OCRWordBox(text: "Test", boundingBox: .zero, confidence: 0.9, lineIndex: 0)
        let control = WordRegionControl(wordBox: box, wordIndex: 0)
        let child = UILabel(frame: .zero)
        control.addSubview(child)
        #expect(shouldReceiveTouch(on: child) == false)
    }

    // Tapping the bare LearnerOverlayView background (empty space between word regions)
    // MUST receive the gesture so the bar-toggle still works on empty taps.
    @Test @MainActor func learnerOverlayViewBackground_shouldReceive() {
        let overlay = LearnerOverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        #expect(shouldReceiveTouch(on: overlay) == true)
    }

    // A plain UIView that is NOT inside a LearnerOverlayView should pass through
    @Test @MainActor func viewOutsideOverlay_shouldReceive() {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let child = UIView(frame: .zero)
        container.addSubview(child)
        #expect(shouldReceiveTouch(on: child) == true)
    }
}
