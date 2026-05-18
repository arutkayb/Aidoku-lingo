//
//  BubbleGrouping.swift
//  Aidoku
//
//  Geometric heuristic for grouping OCR lines/words into manga speech bubbles.
//  Two helpers expose the same heuristic at line and word granularity so the
//  sentence-translation path and the MWE-detection path can share one source
//  of truth.
//

#if canImport(UIKit)
import CoreGraphics
import Foundation

enum BubbleGrouping {

    /// Vertical-distance multiplier (× average line height) that still counts as
    /// "same bubble". Conservative to err on the side of more (smaller) groups.
    static let verticalFactor: CGFloat = 1.5
    /// Required horizontal-overlap ratio (× narrower line width) for two
    /// consecutive lines to be considered the same bubble.
    static let horizontalOverlapFactor: CGFloat = 0.5

    /// Groups consecutive OCR lines into bubbles by bounding-box adjacency.
    /// Returns per-bubble lists of line indices (preserves original input order).
    static func groupLinesIntoBubbles(_ lines: [OCRLineBox]) -> [[Int]] {
        guard !lines.isEmpty else { return [] }
        let avgHeight = lines.map(\.boundingBox.height).reduce(0, +) / CGFloat(lines.count)

        var groups: [[Int]] = []
        var currentGroup: [Int] = [0]

        for i in 1 ..< lines.count {
            let prev = lines[i - 1].boundingBox
            let curr = lines[i].boundingBox

            let prevCentreY = prev.minY + prev.height / 2
            let currCentreY = curr.minY + curr.height / 2
            let vertDist = abs(prevCentreY - currCentreY)

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
        return groups
    }

    /// Groups words into bubbles by reading each word's `lineIndex` and resolving
    /// it through `groupLinesIntoBubbles`. Words whose `lineIndex` does not map
    /// to any line group are collected into a defensive trailing singleton bubble.
    static func groupWordsByBubble(
        words: [OCRWordBox],
        lines: [OCRLineBox]
    ) -> [[Int]] {
        guard !words.isEmpty else { return [] }
        let lineGroups = groupLinesIntoBubbles(lines)

        // Build a map: lineIndex -> bubble index.
        var lineToBubble: [Int: Int] = [:]
        for (bubbleIdx, lineIndices) in lineGroups.enumerated() {
            for lineIdx in lineIndices {
                lineToBubble[lineIdx] = bubbleIdx
            }
        }

        var bubbles: [[Int]] = Array(repeating: [], count: lineGroups.count)
        var orphaned: [Int] = []

        for (wordIdx, word) in words.enumerated() {
            if let bubbleIdx = lineToBubble[word.lineIndex] {
                bubbles[bubbleIdx].append(wordIdx)
            } else {
                orphaned.append(wordIdx)
            }
        }

        if !orphaned.isEmpty {
            bubbles.append(orphaned)
        }
        // Drop any empty bubble (defensive — a line group with no words).
        return bubbles.filter { !$0.isEmpty }
    }
}
#endif // canImport(UIKit)
