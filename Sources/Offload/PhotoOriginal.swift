import AVFoundation
import Foundation
import OffloadCore
import Photos
import os

/// An original of the photo library, addressed by its PhotoKit identifier.
///
/// A video that is on the device is uploaded straight from the library's own
/// file, so it needs no extra space. Everything else is first copied into a
/// folder the caller owns and is expected to delete afterwards.
struct PhotoOriginal: Original {
  private let id: String
  private let folder: URL
  private let lease: Lease

  /// - Parameters:
  ///   - id: PhotoKit local identifier of the asset.
  ///   - folder: Where files are copied to when they cannot be read in place.
  init(id: String, folder: URL) {
    self.id = id
    self.folder = folder
    self.lease = Lease()
  }

  func parts() async throws -> [Part] {
    let found = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
    guard found.count > 0 else {
      throw MissingOriginal()
    }
    let asset = found.object(at: 0)
    let prefix = "\(stamp(asset))_\(id.prefix(8))"
    var parts: [Part] = []
    for (index, resource) in PHAssetResource.assetResources(for: asset).enumerated() {
      let inPlace = await libraryFile(of: asset, holding: resource)
      let file: URL
      if let lent = inPlace.first {
        file = lent
      } else {
        file = try await copy(of: resource, at: index)
      }
      // Two files of one asset may share a filename, so the position tells them apart.
      let taken = parts.contains { $0.name == "\(prefix)_\(resource.originalFilename)" }
      parts.append(
        Part(
          name: "\(prefix)_\(taken ? "\(index)_" : "")\(resource.originalFilename)",
          file: file
        )
      )
    }
    return parts
  }

  func remove() async throws {
    let id = self.id
    try await PHPhotoLibrary.shared().performChanges {
      PHAssetChangeRequest.deleteAssets(
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
      )
    }
  }

  /// The library's own file of the original video; empty when it cannot be read in place.
  ///
  /// PhotoKit lends the file for as long as the video object it returns is
  /// alive, so that object is kept until this original goes away.
  private func libraryFile(of asset: PHAsset, holding resource: PHAssetResource) async -> [URL] {
    guard resource.type == .video else {
      return []
    }
    let options = PHVideoRequestOptions()
    options.version = .original
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = false
    let lent: [AVURLAsset] = await withCheckedContinuation { continuation in
      PHImageManager.default().requestAVAsset(forVideo: asset, options: options) {
        @Sendable video, _, _ in
        continuation.resume(returning: (video as? AVURLAsset).map { [$0] } ?? [])
      }
    }
    guard let video = lent.first, bytes(at: video.url) == ResourceWeight(resource).bytes(),
      (try? FileHandle(forReadingFrom: video.url).close()) != nil
    else {
      return []
    }
    lease.hold(video)
    return [video.url]
  }

  /// A copy of the resource in the caller's folder.
  private func copy(of resource: PHAssetResource, at index: Int) async throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let needed = ResourceWeight(resource).bytes()
    let free = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage ?? .max
    guard needed <= free else {
      throw NoRoomForCopy(name: resource.originalFilename, needed: needed, free: free)
    }
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    let file = folder.appendingPathComponent("\(index)-\(resource.originalFilename)")
    try await PHAssetResourceManager.default().writeData(
      for: resource,
      toFile: file,
      options: options
    )
    return file
  }

  private func bytes(at file: URL) -> Int64 {
    let facts = try? FileManager.default.attributesOfItem(atPath: file.path)
    return (facts?[.size] as? NSNumber)?.int64Value ?? -1
  }

  private func stamp(_ asset: PHAsset) -> String {
    guard let created = asset.creationDate else {
      return "undated"
    }
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return format.string(from: created)
  }
}

/// Video objects PhotoKit lent, kept alive so their files stay readable.
private final class Lease: Sendable {
  private let held = OSAllocatedUnfairLock(initialState: [AVURLAsset]())

  func hold(_ video: AVURLAsset) {
    held.withLock { $0.append(video) }
  }
}

/// The photo library no longer has the asset.
struct MissingOriginal: LocalizedError {
  var errorDescription: String? {
    "This item is no longer in the photo library"
  }
}

/// The device has too little free space to prepare a file for upload.
struct NoRoomForCopy: LocalizedError {
  private let name: String
  private let needed: Int64
  private let free: Int64

  init(name: String, needed: Int64, free: Int64) {
    self.name = name
    self.needed = needed
    self.free = free
  }

  var errorDescription: String? {
    "\(name) has to be copied before upload and needs "
      + "\(needed.formatted(.byteCount(style: .file))), but this iPhone has only "
      + "\(free.formatted(.byteCount(style: .file))) free"
  }
}
