//
//  MWEDetectionServiceFactory.swift
//  Aidoku
//
//  Singleton factory exposing the production MWE detection stack:
//  CachingMWEDetectionService(
//      CompositeMWEDetectionService(
//          primary:  FoundationModelsMWEDetectionService(),
//          fallback: HeuristicMWEDetectionService()
//      )
//  ).
//
//  The composite calls Foundation Models first (best quality when Apple
//  Intelligence is available) and falls back to the dictionary-based
//  HeuristicMWEDetectionService on devices that aren't AI-eligible.
//

import Foundation

enum MWEDetectionServiceFactory {
    static let shared: any MWEDetectionService = CachingMWEDetectionService(
        wrapping: CompositeMWEDetectionService(
            primary: FoundationModelsMWEDetectionService(),
            fallback: HeuristicMWEDetectionService()
        )
    )
}
