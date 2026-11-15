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
    let bundle = Bundle(for: CoreDataManager.self)
    let container: NSPersistentContainer
    if let modelURL = bundle.url(forResource: "Aidoku", withExtension: "momd") {
        guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
            fatalError("Cannot load model from \(modelURL)")
        }
        container = NSPersistentContainer(name: "Aidoku", managedObjectModel: model)
    } else {
        container = NSPersistentContainer(name: "Aidoku")
    }
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
