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
    func newChapterCount(for identifier: MangaIdentifier, context: NSManagedObjectContext) -> Int {
        CoreDataManager.shared.getUnviewedMangaUpdates(
            sourceId: identifier.sourceKey,
            mangaId: identifier.mangaKey,
            context: context
        ).count
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
