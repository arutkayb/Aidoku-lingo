//
//  MWEDetectionServiceFactory.swift
//  Aidoku
//
//  Singleton factory exposing the production MWE detection stack:
//  CachingMWEDetectionService(FoundationModelsMWEDetectionService()).
//

import Foundation

enum MWEDetectionServiceFactory {
    static let shared: any MWEDetectionService = CachingMWEDetectionService(
        wrapping: FoundationModelsMWEDetectionService()
    )
}
