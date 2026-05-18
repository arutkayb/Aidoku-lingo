//
//  MWEDetectionServiceTests.swift
//  AidokuTests
//
//  Swift Testing coverage for the MWE detection stack: validation, overlap
//  resolution, caching, and timeout/retry fallback. No real FoundationModels
//  calls — the runner closure is injected.
//

import Foundation
import Testing
@testable import Aidoku

@Suite struct MWEDetectionServiceTests {

    // MARK: — Fixtures

    private func page(_ bubbles: [[String]]) -> MWEDetectionPage {
        MWEDetectionPage(bubbles: bubbles.map { MWEDetectionBubble(tokens: $0) })
    }

    private func item(
        _ text: String,
        kind: String = "idiom",
        bubble: Int,
        start: Int,
        end: Int
    ) -> FoundationModelsMWEDetectionService.DetectedSpanItem {
        FoundationModelsMWEDetectionService.DetectedSpanItem(
            text: text,
            kindRaw: kind,
            bubbleIndex: bubble,
            startWordIndex: start,
            endWordIndex: end
        )
    }

    private func span(
        _ text: String,
        kind: PhraseKind = .idiom,
        bubble: Int,
        start: Int,
        end: Int
    ) -> DetectedPhraseSpan {
        DetectedPhraseSpan(
            text: text,
            kind: kind,
            bubbleIndex: bubble,
            startWordIndex: start,
            endWordIndex: end,
            confidence: 1.0
        )
    }

    // MARK: — validate

    @Test func validate_dropsOutOfRangeBubbleIndex() {
        let p = page([["a", "b", "c"]])
        let raw = [item("x y", bubble: 5, start: 0, end: 1)]
        let result = FoundationModelsMWEDetectionService.validate(raw, against: p)
        #expect(result.isEmpty)
    }

    @Test func validate_dropsOutOfRangeWordIndex() {
        let p = page([["a", "b", "c"]])
        let raw = [item("x y", bubble: 0, start: 1, end: 99)]
        let result = FoundationModelsMWEDetectionService.validate(raw, against: p)
        #expect(result.isEmpty)
    }

    @Test func validate_dropsSingleTokenSpans() {
        let p = page([["a", "b", "c"]])
        let raw = [item("a", bubble: 0, start: 0, end: 0)]
        let result = FoundationModelsMWEDetectionService.validate(raw, against: p)
        #expect(result.isEmpty)
    }

    @Test func validate_dropsSpansLongerThan6() {
        let p = page([["a", "b", "c", "d", "e", "f", "g", "h"]])
        // 8 tokens (start=0, end=7 → length 8)
        let raw = [item("a b c d e f g h", bubble: 0, start: 0, end: 7)]
        let result = FoundationModelsMWEDetectionService.validate(raw, against: p)
        #expect(result.isEmpty)
    }

    @Test func validate_dropsUnknownKind() {
        let p = page([["a", "b"]])
        let raw = [item("a b", kind: "garbage", bubble: 0, start: 0, end: 1)]
        let result = FoundationModelsMWEDetectionService.validate(raw, against: p)
        #expect(result.isEmpty)
    }

    @Test func validate_acceptsValidSpan() {
        let p = page([["kick", "the", "bucket"]])
        let raw = [item("kick the bucket", kind: "idiom", bubble: 0, start: 0, end: 2)]
        let result = FoundationModelsMWEDetectionService.validate(raw, against: p)
        #expect(result.count == 1)
        #expect(result[0].kind == .idiom)
        #expect(result[0].text == "kick the bucket")
    }

    // MARK: — resolveOverlaps

    @Test func resolveOverlaps_longestWins() {
        // bubble 0 words 0..3: two overlapping spans 0-1 and 0-3. Longer wins.
        let a = span("a b", bubble: 0, start: 0, end: 1)
        let b = span("a b c d", bubble: 0, start: 0, end: 3)
        let out = FoundationModelsMWEDetectionService.resolveOverlaps([a, b])
        #expect(out.count == 1)
        #expect(out[0].endWordIndex - out[0].startWordIndex == 3)
    }

    @Test func resolveOverlaps_leftmostBreaksTies() {
        // Two equal-length overlapping spans at positions (0,1) and (1,2).
        let a = span("a b", bubble: 0, start: 0, end: 1)
        let b = span("b c", bubble: 0, start: 1, end: 2)
        let out = FoundationModelsMWEDetectionService.resolveOverlaps([b, a])
        #expect(out.count == 1)
        #expect(out[0].startWordIndex == 0)
    }

    @Test func resolveOverlaps_keepsNonOverlappingSpans() {
        let a = span("a b", bubble: 0, start: 0, end: 1)
        let b = span("d e", bubble: 0, start: 3, end: 4)
        let out = FoundationModelsMWEDetectionService.resolveOverlaps([a, b])
        #expect(out.count == 2)
    }

    @Test func resolveOverlaps_differentBubblesDoNotOverlap() {
        let a = span("a b", bubble: 0, start: 0, end: 1)
        let b = span("a b", bubble: 1, start: 0, end: 1)
        let out = FoundationModelsMWEDetectionService.resolveOverlaps([a, b])
        #expect(out.count == 2)
    }

    // MARK: — Caching

    @Test func caching_secondCallHits() async throws {
        let stub = StubMWEDetectionService()
        stub.nextResult = .success([span("a b", bubble: 0, start: 0, end: 1)])
        let caching = CachingMWEDetectionService(wrapping: stub)
        let p = page([["a", "b"]])

        _ = try await caching.detect(page: p, sourceLanguage: "en-US")
        _ = try await caching.detect(page: p, sourceLanguage: "en-US")
        #expect(stub.recordedCalls.count == 1)
    }

    @Test func caching_differentLanguageMisses() async throws {
        let stub = StubMWEDetectionService()
        stub.nextResult = .success([])
        let caching = CachingMWEDetectionService(wrapping: stub)
        let p = page([["a", "b"]])

        _ = try await caching.detect(page: p, sourceLanguage: "en-US")
        _ = try await caching.detect(page: p, sourceLanguage: "de-DE")
        #expect(stub.recordedCalls.count == 2)
    }

    // MARK: — Timeout

    @Test func timeout_returnsEmptyAfterRetry() async throws {
        // Inject a runner that always sleeps past the timeout. The service should
        // retry once, time out again, and return [].
        let service = FoundationModelsMWEDetectionService { _ in
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 s
            return []
        }
        // Use a low timeout via the static path so the test stays fast.
        // We can't override the per-call timeout from outside, so we exercise the
        // helper directly with a tight bound.
        let prompt = "test"
        let start = Date()
        var threw = false
        do {
            _ = try await FoundationModelsMWEDetectionService.runWithTimeoutAndRetry(
                seconds: 0.1,
                runner: { _ in
                    try await Task.sleep(nanoseconds: 500_000_000)
                    return []
                },
                prompt: prompt
            )
        } catch {
            threw = true
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(threw == true, "Timeout helper should throw after both attempts fail")
        // Two 100 ms attempts → upper bound around ~500 ms with scheduling slack.
        #expect(elapsed < 1.5, "Timeout did not actually cap call duration: \(elapsed)s")
        _ = service // suppress unused warning
    }

    // MARK: — End-to-end via runner injection

    @Test func detect_appliesValidationAndOverlap() async throws {
        // Runner returns a mix of valid + invalid + overlapping spans; service must
        // emit only the valid, non-overlapping ones.
        let runner: FoundationModelsMWEDetectionService.CallRunner = { _ in
            [
                .init(text: "kick the bucket", kindRaw: "idiom", bubbleIndex: 0, startWordIndex: 0, endWordIndex: 2),
                .init(text: "the bucket", kindRaw: "compound", bubbleIndex: 0, startWordIndex: 1, endWordIndex: 2),
                .init(text: "out", kindRaw: "idiom", bubbleIndex: 0, startWordIndex: 99, endWordIndex: 100),
            ]
        }
        let service = FoundationModelsMWEDetectionService(callRunner: runner)
        let p = page([["kick", "the", "bucket"]])
        let result = try await service.detect(page: p, sourceLanguage: "en-US")
        #expect(result.count == 1)
        #expect(result[0].kind == .idiom)
        #expect(result[0].startWordIndex == 0)
        #expect(result[0].endWordIndex == 2)
    }

    @Test func detect_emptyPageReturnsEmpty() async throws {
        let service = FoundationModelsMWEDetectionService(callRunner: { _ in
            Issue.record("Runner should not be invoked for an empty page")
            return []
        })
        let result = try await service.detect(page: page([]), sourceLanguage: "en-US")
        #expect(result.isEmpty)
    }
}
