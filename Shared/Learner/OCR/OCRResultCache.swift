//
//  OCRResultCache.swift
//  Aidoku
//
//  In-memory NSCache-backed cache for OCRResult, keyed by SHA256(image bytes) + language string.
//  Capacity: 32 entries (one chapter's worth of pages).
//  iOS-only (OCRResult requires UIKit types defined in OCRService.swift).
//

#if canImport(UIKit)
import Foundation
import CryptoKit

/// NSCache requires reference-type values; wrap Sendable OCRResult in a class box.
final class OCRResultBox: NSObject, @unchecked Sendable {
    let value: OCRResult
    init(_ value: OCRResult) { self.value = value }
}

final class OCRResultCache: @unchecked Sendable {

    private let cache = NSCache<NSString, OCRResultBox>()

    init(countLimit: Int = 32) {
        cache.countLimit = countLimit
    }

    /// Returns cached result if present.
    func get(imageData: Data, languages: [String]) -> OCRResult? {
        cache.object(forKey: key(imageData: imageData, languages: languages))?.value
    }

    /// Stores a result for later retrieval.
    func put(imageData: Data, languages: [String], result: OCRResult) {
        cache.setObject(OCRResultBox(result), forKey: key(imageData: imageData, languages: languages))
    }

    /// Removes the cached result for the given image + languages combination, if present.
    func invalidate(imageData: Data, languages: [String]) {
        cache.removeObject(forKey: key(imageData: imageData, languages: languages))
    }

    /// Removes all cached OCR results.
    func removeAll() {
        cache.removeAllObjects()
    }

    // MARK: — Private

    private func key(imageData: Data, languages: [String]) -> NSString {
        let hash = SHA256.hash(data: imageData).compactMap { String(format: "%02x", $0) }.joined()
        return "\(hash)|\(languages.joined(separator: ","))" as NSString
    }
}
#endif // canImport(UIKit)
