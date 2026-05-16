//
//  SavedConnectionThumbnailCache.swift
//  Screen Q
//
//  Disk-backed JPEG cache for last-frame thumbnails attached to saved
//  connections. Keyed by the saved-connection UUID. Augments the inline
//  thumbnail data stored on `SavedConnection` — useful when callers want
//  a fast path that doesn't require touching UserDefaults or paging the
//  whole connections array.
//
//  The cache lives under
//      <Library/Caches>/SavedConnectionThumbnails/<uuid>.jpg
//  Files are tiny (typically 25-60 KB) and disposable: the OS may purge
//  the Caches directory under disk pressure with no impact.
//
//  Thread-safe via a serial utility queue for writes; reads check an
//  in-memory NSCache first to avoid disk hits on hot paths.
//

import Foundation
import CoreGraphics
import ImageIO

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

#if canImport(MobileCoreServices)
import MobileCoreServices
#endif

final class SavedConnectionThumbnailCache {

    static let shared = SavedConnectionThumbnailCache()

    private let directory: URL
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "screen-q.thumbnail-cache", qos: .utility)
    private let inMemory = NSCache<NSString, NSData>()

    init() {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        directory = caches.appendingPathComponent("SavedConnectionThumbnails", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        inMemory.countLimit = 64
    }

    /// Persist JPEG bytes for the given saved-connection id. The completion is
    /// invoked on the main queue with the timestamp the file was written at,
    /// so callers can mirror that into `SavedConnection.thumbnailUpdatedAt`.
    func store(jpeg: Data, for id: UUID, completion: ((Date) -> Void)? = nil) {
        let now = Date()
        queue.async {
            let url = self.url(for: id)
            try? jpeg.write(to: url, options: .atomic)
            self.inMemory.setObject(jpeg as NSData, forKey: id.uuidString as NSString)
            if let completion {
                DispatchQueue.main.async { completion(now) }
            }
        }
    }

    /// Returns the cached JPEG payload, lazily promoting it into the in-memory
    /// cache on first read. Returns `nil` if no cached image exists.
    func loadData(for id: UUID) -> Data? {
        let key = id.uuidString as NSString
        if let mem = inMemory.object(forKey: key) {
            return mem as Data
        }
        let url = self.url(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        inMemory.setObject(data as NSData, forKey: key)
        return data
    }

    /// Discard the cached thumbnail for the given id, both on disk and in-memory.
    func remove(_ id: UUID) {
        let key = id.uuidString as NSString
        queue.async {
            let url = self.url(for: id)
            try? self.fileManager.removeItem(at: url)
            self.inMemory.removeObject(forKey: key)
        }
    }

    /// Wipe the entire cache. Intended for "clear all recents" or sign-out flows.
    func removeAll() {
        queue.async {
            try? self.fileManager.removeItem(at: self.directory)
            try? self.fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
            self.inMemory.removeAllObjects()
        }
    }

    /// Convenience helper that compresses a CGImage to JPEG at the given quality.
    /// Uses ImageIO directly so it's identical on macOS 11.5 and iOS 17.
    static func jpegData(from cgImage: CGImage, quality: CGFloat = 0.7) -> Data? {
        let data = NSMutableData()
        let typeID = "public.jpeg" as CFString
        guard let dest = CGImageDestinationCreateWithData(data, typeID, 1, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: max(0, min(1, quality))
        ]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Private helpers

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }
}
