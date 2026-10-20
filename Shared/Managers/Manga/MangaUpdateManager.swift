//
//  MangaUpdateManager.swift
//  Aidoku
//
//  Created by axiel7 on 17/03/2024.
//

import AidokuRunner
import CoreData

struct MangaUpdateManager {
    static let shared = MangaUpdateManager()
}

extension MangaUpdateManager {
    func newlyDownloadedChapterCount(
        for identifier: MangaIdentifier,
        context: NSManagedObjectContext,
        isDownloaded: (ChapterIdentifier) -> Bool = { DownloadManager.shared.getDownloadStatus(for: $0) == .finished }
    ) -> Int {
        CoreDataManager.shared.getUnviewedMangaUpdates(
            sourceId: identifier.sourceKey,
            mangaId: identifier.mangaKey,
            context: context
        ).reduce(into: 0) { count, update in
            if isDownloaded(update.identifier) {
                count += 1
            }
        }
    }

    func viewAllUpdates(of manga: AidokuRunner.Manga) async {
        await CoreDataManager.shared.container.performBackgroundTask { context in
            let updates = CoreDataManager.shared.setMangaUpdatesViewed(
                sourceId: manga.sourceKey,
                mangaId: manga.key,
                context: context
            )
            if !updates.isEmpty {
                NotificationCenter.default.post(name: NSNotification.Name("mangaUpdatesViewed"), object: updates.map { $0.toItem() })
            }
        }
    }
}
