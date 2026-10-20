import Testing

@testable import Aidoku

@MainActor
struct DownloadTaskStartupTests {
    @Test func initialDelegateReceivesCompletion() async {
        let delegate = DownloadStartupDelegate()
        let task = DownloadTask(id: "test", cache: DownloadCache(), downloads: [], delegate: delegate)

        await task.resume()
        await delegate.waitForCompletion()

        #expect(await delegate.completions == 1)
    }
}

private actor DownloadStartupDelegate: DownloadTaskDelegate {
    private(set) var completions = 0
    private var waiter: CheckedContinuation<Void, Never>?

    func waitForCompletion() async {
        guard completions == 0 else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func taskFinished(task: DownloadTask) {
        completions += 1
        waiter?.resume()
        waiter = nil
    }

    func taskCancelled(task: DownloadTask) {}
    func taskPaused(task: DownloadTask) {}
    func downloadProgressChanged(download: Download) {}
    func downloadFinished(download: Download) {}
    func downloadCancelled(download: Download) {}
}
