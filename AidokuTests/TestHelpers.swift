//
//  TestHelpers.swift
//  AidokuTests
//
//  Shared test utilities used across multiple test suites.
//

import Foundation
import CoreData
@testable import Aidoku

// MARK: — Stub MWE detection service

/// Records detect() calls and returns scripted results. Mirrors `StubTranslationService`.
final class StubMWEDetectionService: MWEDetectionService, @unchecked Sendable {
    struct Call: Sendable {
        let page: MWEDetectionPage
        let sourceLanguage: String
    }

    var recordedCalls: [Call] = []
    var nextResult: Result<[DetectedPhraseSpan], Error> = .success([])

    func detect(page: MWEDetectionPage, sourceLanguage: String) async throws -> [DetectedPhraseSpan] {
        recordedCalls.append(Call(page: page, sourceLanguage: sourceLanguage))
        switch nextResult {
        case .success(let spans):
            return spans
        case .failure(let error):
            throw error
        }
    }
}

// MARK: — In-memory CoreData container

/// Returns a fully configured NSPersistentContainer backed by NSInMemoryStoreType.
/// Suitable for unit tests that need Core Data without a persistent store.
func makeInMemoryContainer() -> NSPersistentContainer {
    let bundle = Bundle(for: CoreDataManager.self)
    guard let modelURL = bundle.url(forResource: "Aidoku", withExtension: "momd") else {
        let container = NSPersistentContainer(name: "Aidoku")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error { fatalError("In-memory store error: \(error)") }
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        return container
    }
    guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
        fatalError("Cannot load model from \(modelURL)")
    }
    let container = NSPersistentContainer(name: "Aidoku", managedObjectModel: model)
    let description = NSPersistentStoreDescription()
    description.type = NSInMemoryStoreType
    container.persistentStoreDescriptions = [description]
    container.loadPersistentStores { _, error in
        if let error { fatalError("In-memory store error: \(error)") }
    }
    container.viewContext.automaticallyMergesChangesFromParent = true
    return container
}
