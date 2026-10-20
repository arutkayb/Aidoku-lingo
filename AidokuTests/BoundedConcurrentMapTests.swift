import Foundation
import Testing

@testable import Aidoku

struct BoundedConcurrentMapTests {
    @Test func completesChecksSeriallyWithinEachSource() async {
        let probe = SourceConcurrencyProbe()
        let sources = ["first", "first", "second", "second", "third", "third"]
        let results = await sources.concurrentMap(maxConcurrentTasks: 3, serializingBy: { $0 }, { source in
            await probe.begin(source)
            try? await Task.sleep(nanoseconds: 20_000_000)
            await probe.end(source)
            return source
        })

        #expect(results == sources)
        #expect(await probe.maximumWithinSource == 1)
        #expect(await probe.maximumAcrossSources > 1)
    }

    @Test func oneSourceReportsEachCompleteCheckBeforeStartingTheNext() async {
        let recorder = SourceCheckRecorder()
        let results = await Array(0..<4).concurrentMap(maxConcurrentTasks: 10, serializingBy: { _ in "source" }, { manga in
            await recorder.record("details:\(manga)")
            try? await Task.sleep(nanoseconds: 5_000_000)
            await recorder.record("chapters:\(manga)")
            await recorder.record("complete:\(manga)")
            return manga
        })

        #expect(results == Array(0..<4))
        #expect(await recorder.events == (0..<4).flatMap { ["details:\($0)", "chapters:\($0)", "complete:\($0)"] })
    }

    @Test func groupedCancellationPreservesStartedChecksAndStopsPendingChecks() async {
        let probe = ConcurrentMapProbe()
        let task = Task {
            await Array(0..<4).concurrentMap(maxConcurrentTasks: 2, serializingBy: { $0 / 2 }, { manga in
                await probe.begin()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await probe.end()
                return manga
            })
        }
        await probe.waitForStarts(2)
        task.cancel()

        #expect(await task.value == [0, 2])
        #expect(await probe.started == 2)
    }

    @Test func overlapsWorkWithoutExceedingTheLimit() async {
        let probe = ConcurrentMapProbe()
        let results = await Array(0..<12).concurrentMap(maxConcurrentTasks: 3) { value in
            await probe.begin()
            try? await Task.sleep(nanoseconds: 20_000_000)
            await probe.end()
            return value * 2
        }

        #expect(results == Array(0..<12).map { $0 * 2 })
        let peak = await probe.peak
        #expect(peak > 1)
        #expect(peak <= 3)
    }

    @Test func emptyInputDoesNoWork() async {
        let probe = ConcurrentMapProbe()
        let results = await [Int]().concurrentMap(maxConcurrentTasks: 3) { value in
            await probe.begin()
            return value
        }

        #expect(results.isEmpty)
        #expect(await probe.peak == 0)
    }

    @Test func cancellationDoesNotStartRemainingItems() async {
        let probe = ConcurrentMapProbe()
        let task = Task {
            await Array(0..<100).concurrentMap(maxConcurrentTasks: 2) { value in
                await probe.begin()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await probe.end()
                return value
            }
        }
        await probe.waitForStart()
        task.cancel()
        _ = await task.value

        #expect(await probe.started <= 2)
    }

    @Test func cancellationPreservesResultsFromStartedWork() async {
        let probe = ConcurrentMapProbe()
        let task = Task {
            await [0, 1].concurrentMap(maxConcurrentTasks: 2) { value in
                await probe.begin()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await probe.end()
                return value
            }
        }
        await probe.waitForStarts(2)
        task.cancel()

        #expect(await task.value == [0, 1])
    }
}

private actor SourceConcurrencyProbe {
    private var activeBySource: [String: Int] = [:]
    private var active = 0
    private(set) var maximumWithinSource = 0
    private(set) var maximumAcrossSources = 0

    func begin(_ source: String) {
        activeBySource[source, default: 0] += 1
        active += 1
        maximumWithinSource = max(maximumWithinSource, activeBySource[source, default: 0])
        maximumAcrossSources = max(maximumAcrossSources, active)
    }

    func end(_ source: String) {
        activeBySource[source, default: 0] -= 1
        active -= 1
    }
}

private actor SourceCheckRecorder {
    private(set) var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }
}

private actor ConcurrentMapProbe {
    private var active = 0
    private(set) var peak = 0
    private(set) var started = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func begin() {
        active += 1
        started += 1
        peak = max(peak, active)
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
    }

    func end() {
        active -= 1
    }

    func waitForStart() async {
        await waitForStarts(1)
    }

    func waitForStarts(_ count: Int) async {
        while started < count {
            await withCheckedContinuation { startWaiters.append($0) }
        }
    }
}
