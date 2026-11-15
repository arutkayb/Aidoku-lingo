//
//  TestHelpers.swift
//  AidokuTests
//
//  Shared test utilities used across multiple test suites.
//

import Foundation
import CoreData
@testable import Aidoku

// MARK: — In-memory CoreData container

/// Returns a fully configured NSPersistentContainer backed by an in-memory SQLite store.
/// Suitable for unit tests that need Core Data without a persistent store.
func makeInMemoryContainer() -> NSPersistentContainer {
    // Reuse the host app's model. A second model instance makes entity lookup by class ambiguous, and saves crash.
    let container = NSPersistentContainer(
        name: "Aidoku",
        managedObjectModel: CoreDataManager.shared.container.managedObjectModel
    )
    // NSInMemoryStoreType rejects the model's derived attributes. SQLite at /dev/null also stays in memory.
    let description = NSPersistentStoreDescription(url: URL(fileURLWithPath: "/dev/null"))
    description.type = NSSQLiteStoreType
    container.persistentStoreDescriptions = [description]
    container.loadPersistentStores { _, error in
        if let error { fatalError("In-memory store error: \(error)") }
    }
    container.viewContext.automaticallyMergesChangesFromParent = true
    return container
}
