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
            for (left, right) in zip(visible, visible.dropFirst()) {
                #expect(abs(left.frame.maxX - right.frame.minX) < 0.5)
            }
        }
    }

    private func makeController() -> LibraryViewController {
        let controller = LibraryViewController()
        controller.collectionView = UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        controller.dataSource = UICollectionViewDiffableDataSource(collectionView: controller.collectionView) { _, _, _ in nil }
        return controller
    }
}
