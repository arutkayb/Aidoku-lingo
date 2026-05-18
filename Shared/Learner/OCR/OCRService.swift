//
//  OCRService.swift
//  Aidoku
//
//  Protocol and value types for the OCR service layer.
//  OCR is iOS-only (Vision + UIKit); the entire file is guarded accordingly.
//

#if canImport(UIKit)
import Foundation
import CoreGraphics
import UIKit

// MARK: — Value types

/// A word-level bounding box returned by OCR.
/// `boundingBox` is in Vision's normalized coordinate space: origin bottom-left, range [0,1].
public struct OCRWordBox: Sendable, Hashable {
    public let text: String
    /// Normalized bounding box in Vision coordinate space (bottom-left origin, values 0…1).
    public let boundingBox: CGRect
    public let confidence: Float
    /// Index into `OCRResult.lines` for the line this word belongs to.
    public let lineIndex: Int

    public init(text: String, boundingBox: CGRect, confidence: Float, lineIndex: Int) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.lineIndex = lineIndex
    }
}

/// A line-level bounding box returned by OCR.
public struct OCRLineBox: Sendable, Hashable {
    public let text: String
    /// Normalized bounding box in Vision coordinate space (bottom-left origin, values 0…1).
    public let boundingBox: CGRect
    public let confidence: Float

    public init(text: String, boundingBox: CGRect, confidence: Float) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

/// A detected multi-word expression spanning one or more `OCRWordBox` entries.
/// `wordIndices` are absolute indices into `OCRResult.words`, ascending and contiguous.
public struct OCRPhrase: Sendable, Hashable {
    public let text: String
    public let kind: PhraseKind
    public let wordIndices: [Int]
    public let lineIndices: [Int]
    public let boundingBox: CGRect
    public let confidence: Float

    public init(
        text: String,
        kind: PhraseKind,
        wordIndices: [Int],
        lineIndices: [Int],
        boundingBox: CGRect,
        confidence: Float
    ) {
        self.text = text
        self.kind = kind
        self.wordIndices = wordIndices
        self.lineIndices = lineIndices
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

/// The complete OCR result for one image.
public struct OCRResult: Sendable, Hashable {
    public let words: [OCRWordBox]
    public let lines: [OCRLineBox]
    public let phrases: [OCRPhrase]

    public init(words: [OCRWordBox], lines: [OCRLineBox], phrases: [OCRPhrase] = []) {
        self.words = words
        self.lines = lines
        self.phrases = phrases
    }
}

// MARK: — Error

public enum OCRError: Error, Sendable {
    case imageUnsupported
    case cancelled
    case requestFailed(Error)
}

// MARK: — Protocol

public protocol OCRService: Sendable {
    /// Recognize text in `image` using the given language hints.
    /// Returns word-level and line-level bounding boxes in Vision normalized coordinates.
    func recognize(image: UIImage, languages: [String]) async throws -> OCRResult
}
#endif // canImport(UIKit)
