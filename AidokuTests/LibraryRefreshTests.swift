import AidokuRunner
import CoreData
import Testing
import UIKit

@testable import Aidoku

@MainActor
struct LibraryRefreshTests {
    @Test func refreshTargetsMatchDisplayedTitlesWhileTheModelReloads() {
        let controller = makeController()
        let visible = MangaInfo(mangaId: "visible", sourceId: "source", title: "Visible")
        let hidden = MangaInfo(mangaId: "hidden", sourceId: "source", title: "Hidden")
        var snapshot = NSDiffableDataSourceSnapshot<OldMangaCollectionViewController.Section, MangaInfo>()
        snapshot.appendSections([.regular])
        snapshot.appendItems([visible])
        controller.dataSource.apply(snapshot, animatingDifferences: false)
        controller.viewModel.manga = [visible, hidden]

        #expect(controller.refreshMangaIdentifiers == [visible.identifier])
    }

    @Test func refreshTargetsIncludePinnedAndFilteredSearchResults() async {
        let controller = makeController()
        let viewModel = controller.viewModel
        let visible = MangaInfo(mangaId: "visible", sourceId: "source", title: "Matching title")
        let pinned = MangaInfo(mangaId: "pinned", sourceId: "source", title: "Matching pinned")
        let hidden = MangaInfo(mangaId: "hidden", sourceId: "source", title: "Other")
        viewModel.manga = [visible, hidden]
        viewModel.pinnedManga = [pinned]

        await viewModel.search(query: "Matching")
        var snapshot = NSDiffableDataSourceSnapshot<OldMangaCollectionViewController.Section, MangaInfo>()
        snapshot.appendSections([.pinned, .regular])
        snapshot.appendItems(viewModel.pinnedManga, toSection: .pinned)
        snapshot.appendItems(viewModel.manga, toSection: .regular)
        await controller.dataSource.apply(snapshot, animatingDifferences: false)

        #expect(controller.refreshMangaIdentifiers == [visible.identifier, pinned.identifier])
    }

    @Test func emptyFilteredLibraryHasNoRefreshTargets() {
        #expect(makeController().refreshMangaIdentifiers.isEmpty)
    }

    @Test func refreshFetchExcludesHiddenTitlesAndOtherSources() {
        let container = makeInMemoryContainer()
        let context = container.viewContext
        let visible = MangaIdentifier(sourceKey: "source", mangaKey: "visible")
        for identifier in [visible, .init(sourceKey: "other", mangaKey: "visible"), .init(sourceKey: "source", mangaKey: "hidden")] {
            CoreDataManager.shared.addToLibrary(
                manga: .init(sourceKey: identifier.sourceKey, key: identifier.mangaKey, title: "Title"),
                chapters: [],
                context: context
            )
        }

        let result = CoreDataManager.shared.getLibraryManga(identifiers: [visible], context: context)

        #expect(result.compactMap { $0.manga?.identifier } == [visible])
        #expect(CoreDataManager.shared.getLibraryManga(identifiers: [], context: context).isEmpty)
    }

    @Test func refreshFetchSupportsLargeLibraries() throws {
        let container = makeInMemoryContainer()
        let context = container.viewContext
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
        try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                           at: directory.appendingPathComponent("Library.sqlite"))
        defer {
            for store in coordinator.persistentStores {
                try? coordinator.remove(store)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let identifiers = Set((0..<1_200).map { MangaIdentifier(sourceKey: "source", mangaKey: String($0)) })
        for identifier in identifiers {
            let manga = MangaObject(context: context)
            manga.load(from: AidokuRunner.Manga(sourceKey: identifier.sourceKey, key: identifier.mangaKey, title: "Title"))
            let libraryManga = LibraryMangaObject(context: context)
            libraryManga.manga = manga
        }
        try context.save()
        context.reset()

        #expect(CoreDataManager.shared.getLibraryManga(identifiers: identifiers, context: context).count == identifiers.count)
    }

    @Test func refreshCountsEachDisplayedMangaOnlyOnce() {
        let container = makeInMemoryContainer()
        let context = container.viewContext
        let identifier = MangaIdentifier(sourceKey: "source", mangaKey: "visible")
        for _ in 0..<2 {
            let manga = CoreDataManager.shared.createManga(.init(sourceKey: "source", key: "visible", title: "Title"), context: context)
            let libraryManga = LibraryMangaObject(context: context)
            libraryManga.manga = manga
        }

        let targets = MangaManager.libraryRefreshTargets(identifiers: [identifier], context: context)

        #expect(targets.map(\.identifier) == [identifier])
    }

    @Test func repeatedRefreshReportsOnlyUnseenChaptersAsNew() {
        let container = makeInMemoryContainer()
        let context = container.viewContext
        let manga = AidokuRunner.Manga(sourceKey: "source", key: "manga", title: "Title")
        let existing = AidokuRunner.Chapter(key: "existing")
        let latest = AidokuRunner.Chapter(key: "latest")
        CoreDataManager.shared.addToLibrary(manga: manga, chapters: [existing], context: context)

        let inserted = CoreDataManager.shared.setChapters(
            [latest, existing], sourceId: manga.sourceKey, mangaId: manga.key, context: context
        )

        #expect(inserted.map(\.id) == ["latest"])
        #expect(CoreDataManager.shared.setChapters(
            [latest, existing], sourceId: manga.sourceKey, mangaId: manga.key, context: context
        ).isEmpty)
    }

    @Test func newChapterCountIncludesUndownloadedAndExcludesViewedAndOtherTitles() {
        let container = makeInMemoryContainer()
        let context = container.viewContext
        let identifier = MangaIdentifier(sourceKey: "source", mangaKey: "manga")
        for (source, manga, chapter, viewed) in [
            ("source", "manga", "first", false),
            ("source", "manga", "second", false),
            ("source", "manga", "viewed", true),
            ("other", "manga", "otherSource", false),
            ("source", "other", "otherManga", false)
        ] {
            let update = MangaUpdateObject(context: context)
            update.sourceId = source
            update.mangaId = manga
            update.chapterId = chapter
            update.viewed = viewed
        }

        #expect(MangaUpdateManager.shared.newChapterCount(for: identifier, context: context) == 2)

        CoreDataManager.shared.setMangaUpdatesViewed(sourceId: "source", mangaId: "manga", context: context)

        #expect(MangaUpdateManager.shared.newChapterCount(for: identifier, context: context) == 0)
    }

    @Test func thirdBadgeCanAppearAloneAndAlongsideExistingCounts() {
        let badge = DoubleBadgeView()
        badge.badgeNumber3 = 2
        let singleWidth = badge.intrinsicContentSize.width
        #expect(singleWidth > 0)

        badge.badgeNumber = 10
        badge.badgeNumber2 = 20
        #expect(badge.intrinsicContentSize.width > singleWidth)

        badge.badgeNumber = 0
        badge.badgeNumber2 = 0
        badge.badgeNumber3 = 0
        #expect(badge.intrinsicContentSize.width == 0)
    }

    @Test func badgeSegmentsRemainAdjacentForEveryCountCombination() {
        let badge = DoubleBadgeView()
        for counts in [(0, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 1, 0), (1, 0, 1), (0, 1, 1), (1, 1, 1)] {
            badge.badgeNumber = counts.0
            badge.badgeNumber2 = counts.1
            badge.badgeNumber3 = counts.2
            badge.frame = CGRect(origin: .zero, size: badge.intrinsicContentSize)
            badge.layoutIfNeeded()
            let visible = badge.subviews.filter { !$0.isHidden }
            #expect(visible.count == counts.0 + counts.1 + counts.2)
            if let first = visible.first, let last = visible.last {
                #expect(abs(first.frame.minX) < 0.5, "counts \(counts)")
                #expect(abs(last.frame.maxX - badge.bounds.width) < 0.5, "counts \(counts)")
            }
            for (left, right) in zip(visible, visible.dropFirst()) {
                #expect(abs(left.frame.maxX - right.frame.minX) < 0.5, "counts \(counts)")
            }
        }
    }

    @Test func pullToRefreshSavesNewChaptersWithoutQueueingDownloads() async {
        let manga = AidokuRunner.Manga(sourceKey: "test-pull-source", key: "test-pull-manga", title: "Pull Test")
        let identifier = manga.identifier
        let previousSkipTitles = UserDefaults.standard.object(forKey: "Library.skipTitles")
        UserDefaults.standard.set([String](), forKey: "Library.skipTitles")
        await SourceManager.shared.waitForSourcesLoad()
        SourceManager.shared.sources.append(AidokuRunner.Source(
            key: manga.sourceKey,
            name: "Pull Test",
            version: 1,
            contentRating: .safe,
            runner: ChapterListRunner(chapterKeys: ["new", "old"])
        ))
        let queued = QueuedDownloadRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: .downloadsQueued, object: nil, queue: nil
        ) { notification in
            let downloads = notification.object as? [Download] ?? []
            queued.record(downloads.filter { $0.mangaIdentifier == identifier }.map(\.chapterIdentifier.chapterKey))
        }
        let container = CoreDataManager.shared.container
        defer {
            UserDefaults.standard.set(previousSkipTitles, forKey: "Library.skipTitles")
            NotificationCenter.default.removeObserver(observer)
            SourceManager.shared.sources.removeAll { $0.key == manga.sourceKey }
            let context = container.newBackgroundContext()
            context.performAndWait {
                CoreDataManager.shared.removeChapters(sourceId: manga.sourceKey, mangaId: manga.key, context: context)
                if let libraryObject = CoreDataManager.shared.getLibraryManga(
                    sourceId: manga.sourceKey, mangaId: manga.key, context: context
                ) {
                    context.delete(libraryObject)
                }
                CoreDataManager.shared.removeManga(sourceId: manga.sourceKey, mangaId: manga.key, context: context)
                try? context.save()
            }
        }
        await container.performBackgroundTask { context in
            CoreDataManager.shared.addToLibrary(manga: manga, chapters: [.init(key: "old")], context: context)
            try? context.save()
        }

        await makeController().refreshVisibleLibrary(identifiers: [identifier], skipReachabilityCheck: true)

        let (chapterKeys, newChapters) = await container.performBackgroundTask { context in
            (
                CoreDataManager.shared.getChapters(sourceId: manga.sourceKey, mangaId: manga.key, context: context)
                    .map(\.id).sorted(),
                MangaUpdateManager.shared.newChapterCount(for: identifier, context: context)
            )
        }
        #expect(chapterKeys == ["new", "old"])
        #expect(newChapters == 1)
        #expect(queued.chapterKeys.isEmpty)
    }

    @Test func pullToRefreshSkipsTitlesWithMoreThanThreeUnreadChapters() async {
        let sourceKey = "test-skip-source"
        let threeUnread = AidokuRunner.Manga(sourceKey: sourceKey, key: "three-unread", title: "Three Unread")
        let fourUnread = AidokuRunner.Manga(sourceKey: sourceKey, key: "four-unread", title: "Four Unread")
        let existing = ["c1", "c2", "c3", "c4", "c5"]
        let previousSkipTitles = UserDefaults.standard.object(forKey: "Library.skipTitles")
        UserDefaults.standard.set(["hasUnread"], forKey: "Library.skipTitles")
        await SourceManager.shared.waitForSourcesLoad()
        SourceManager.shared.sources.append(AidokuRunner.Source(
            key: sourceKey,
            name: "Skip Test",
            version: 1,
            contentRating: .safe,
            runner: ChapterListRunner(chapterKeys: ["new"] + existing.reversed())
        ))
        let container = CoreDataManager.shared.container
        defer {
            UserDefaults.standard.set(previousSkipTitles, forKey: "Library.skipTitles")
            SourceManager.shared.sources.removeAll { $0.key == sourceKey }
            let context = container.newBackgroundContext()
            context.performAndWait {
                for manga in [threeUnread, fourUnread] {
                    CoreDataManager.shared.removeHistory(sourceId: manga.sourceKey, mangaId: manga.key, context: context)
                    CoreDataManager.shared.removeChapters(sourceId: manga.sourceKey, mangaId: manga.key, context: context)
                    if let libraryObject = CoreDataManager.shared.getLibraryManga(
                        sourceId: manga.sourceKey, mangaId: manga.key, context: context
                    ) {
                        context.delete(libraryObject)
                    }
                    CoreDataManager.shared.removeManga(sourceId: manga.sourceKey, mangaId: manga.key, context: context)
                }
                try? context.save()
            }
        }
        await container.performBackgroundTask { context in
            for (manga, readCount) in [(threeUnread, 2), (fourUnread, 1)] {
                CoreDataManager.shared.addToLibrary(manga: manga, chapters: existing.map { .init(key: $0) }, context: context)
                _ = CoreDataManager.shared.setCompleted(
                    sourceId: manga.sourceKey,
                    mangaId: manga.key,
                    chapterIds: Array(existing.prefix(readCount)),
                    date: .now,
                    context: context
                )
            }
            try? context.save()
        }

        await makeController().refreshVisibleLibrary(
            identifiers: [threeUnread.identifier, fourUnread.identifier], skipReachabilityCheck: true
        )

        let checked = await container.performBackgroundTask { context in
            [threeUnread, fourUnread].map { manga in
                CoreDataManager.shared.getChapters(sourceId: manga.sourceKey, mangaId: manga.key, context: context)
                    .contains { $0.id == "new" }
            }
        }
        #expect(checked == [true, false])
    }

    @Test func readingOrCompletingAChapterClearsOnlyItsNewChapterCount() async {
        let manga = AidokuRunner.Manga(sourceKey: "test-read-source", key: "test-read-manga", title: "Read Test")
        let identifier = manga.identifier
        let container = CoreDataManager.shared.container
        defer {
            let context = container.newBackgroundContext()
            context.performAndWait {
                CoreDataManager.shared.removeHistory(sourceId: manga.sourceKey, mangaId: manga.key, context: context)
                CoreDataManager.shared.removeChapters(sourceId: manga.sourceKey, mangaId: manga.key, context: context)
                if let libraryObject = CoreDataManager.shared.getLibraryManga(
                    sourceId: manga.sourceKey, mangaId: manga.key, context: context
                ) {
                    context.delete(libraryObject)
                }
                CoreDataManager.shared.removeManga(sourceId: manga.sourceKey, mangaId: manga.key, context: context)
                try? context.save()
            }
        }
        let read = AidokuRunner.Chapter(key: "read")
        let completed = AidokuRunner.Chapter(key: "completed")
        await container.performBackgroundTask { context in
            CoreDataManager.shared.addToLibrary(manga: manga, chapters: [read, completed, .init(key: "unread")], context: context)
            for chapter in CoreDataManager.shared.getChapters(sourceId: manga.sourceKey, mangaId: manga.key, context: context) {
                CoreDataManager.shared.createMangaUpdate(
                    sourceId: manga.sourceKey, mangaId: manga.key, chapterObject: chapter, context: context
                )
            }
            try? context.save()
        }
        func newChapterCount() async -> Int {
            await container.performBackgroundTask { MangaUpdateManager.shared.newChapterCount(for: identifier, context: $0) }
        }

        await HistoryManager.shared.setProgress(
            chapter: read.toOld(sourceId: manga.sourceKey, mangaId: manga.key), progress: 2, totalPages: 10, completed: false
        )
        let afterReading = await newChapterCount()
        await HistoryManager.shared.addHistory(sourceId: manga.sourceKey, mangaId: manga.key, chapters: [completed])
        let afterCompleting = await newChapterCount()

        #expect(afterReading == 2)
        #expect(afterCompleting == 1)
    }

    @Test func updatesTabMarksOnlyTheNotifiedChaptersViewed() {
        let manga = AidokuRunner.Manga(sourceKey: "source", key: "manga", title: "Title")
        let updates = ["read", "unread"].map { key in
            MangaUpdatesView.UpdateInfo(
                id: key,
                chapterIdentifier: .init(sourceKey: "source", mangaKey: "manga", chapterKey: key),
                date: .now,
                manga: manga,
                chapter: nil,
                viewed: false
            )
        }
        let entries = [MangaUpdatesView.UpdateSection(day: 0, items: [.init(mangaKey: "manga", updates: updates)])]

        let result = MangaUpdatesView.markingViewed(
            entries, items: [MangaUpdateItem(sourceId: "source", chapterId: "read", mangaId: "manga", viewed: true)]
        )

        #expect(result[0].items[0].updates.map(\.viewed) == [true, false])

        let allViewed = MangaUpdatesView.markingViewed(entries, items: ["read", "unread"].map {
            MangaUpdateItem(sourceId: "source", chapterId: $0, mangaId: "manga", viewed: true)
        })

        #expect(allViewed[0].items[0].updates.map(\.viewed) == [true, true])
    }

    private func makeController() -> LibraryViewController {
        let controller = LibraryViewController()
        controller.collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        controller.dataSource = UICollectionViewDiffableDataSource(collectionView: controller.collectionView) { _, _, _ in nil }
        return controller
    }
}

private struct ChapterListRunner: AidokuRunner.Runner {
    let chapterKeys: [String]
    let features = AidokuRunner.SourceFeatures()

    func getSearchMangaList(
        query: String?, page: Int, filters: [AidokuRunner.FilterValue]
    ) async throws -> AidokuRunner.MangaPageResult {
        AidokuRunner.MangaPageResult(entries: [], hasNextPage: false)
    }

    func getMangaUpdate(
        manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool
    ) async throws -> AidokuRunner.Manga {
        var manga = manga
        manga.chapters = chapterKeys.map { AidokuRunner.Chapter(key: $0) }
        return manga
    }

    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        []
    }
}

private final class QueuedDownloadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String] = []

    var chapterKeys: [String] {
        lock.withLock { keys }
    }

    func record(_ chapterKeys: [String]) {
        lock.withLock { keys += chapterKeys }
    }
}
