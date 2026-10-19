import AVFoundation
import Foundation
import SpacekeeperCore
import Photos
import os

/// Lays the files of library items ready for upload in the outbox's store.
///
/// Each file is given its place in the cloud: a folder for the year and
/// month the item was made, and a name that starts with that moment.
///
/// The system can only upload a file that lies in the app's own folders
/// while the app is closed, so each file of an item is placed there. A video
/// that is on the device is placed as a clone, which shares its storage with
/// the library's file and so needs no extra space; everything else is copied.
struct Staging: Sendable {
  private let store: URL
  private let log = Logger(subsystem: "Spacekeeper", category: "staging")

  /// - Parameter store: Folder the outbox sends from.
  init(store: URL) {
    self.store = store
  }

  /// The item as a consignment, with its files lying in a folder of their own.
  func consignment(of item: MediaItem, aim: Aim) async throws -> Consignment {
    let found = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil)
    guard found.count > 0 else {
      throw MissingOriginal()
    }
    let asset = found.object(at: 0)
    let folder = UUID().uuidString
    let place = store.appendingPathComponent(folder)
    do {
      try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
      // What waits here is on its way to a cloud already, so backups leave it out.
      var unsaved = URLResourceValues()
      unsaved.isExcludedFromBackup = true
      var root = store
      try? root.setResourceValues(unsaved)
      let taken = asset.creationDate ?? .distantPast
      let resources = PHAssetResource.assetResources(for: asset)
      let names = Placement(taken: taken, id: item.id, zone: .current)
        .paths(for: resources.map { $0.originalFilename })
      var parcels: [Parcel] = []
      for (index, resource) in resources.enumerated() {
        let file = place.appendingPathComponent("\(index)-\(resource.originalFilename)")
        let started = Date()
        let cloned = await clone(of: resource, in: asset, at: file)
        if !cloned {
          try await copy(of: resource, at: file)
        }
        let name = names[index]
        let print = try FingerprintOf(file).value()
        let how = cloned ? "cloned" : "copied"
        let seconds = Date().timeIntervalSince(started)
        log.notice(
          """
          \(name, privacy: .private(mask: .hash)): \(how, privacy: .public) \(bytes(at: file)) bytes \
          and read them in \(seconds, format: .fixed(precision: 2)) s
          """
        )
        parcels.append(
          Parcel(
            name: name,
            file: "\(folder)/\(file.lastPathComponent)",
            bytes: bytes(at: file),
            print: print,
            taken: taken
          )
        )
      }
      return try Consignment(
        item: item,
        stamp: asset.modificationDate ?? .distantPast,
        parcels: parcels,
        aim: aim
      )
    } catch {
      try? FileManager.default.removeItem(at: place)
      throw error
    }
  }

  /// Places the library's own file of an original video as a clone; false when it cannot.
  ///
  /// PhotoKit lends the file for as long as the video object it returns is
  /// alive, so that object is kept until the clone is made. A clone is
  /// insisted on: an ordinary copy is made elsewhere, after checking for room.
  private func clone(of resource: PHAssetResource, in asset: PHAsset, at file: URL) async -> Bool {
    guard resource.type == .video else {
      return false
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
    guard let video = lent.first, bytes(at: video.url) == ResourceWeight(resource).bytes() else {
      return false
    }
    let refused = withExtendedLifetime(video) {
      copyfile(video.url.path, file.path, nil, copyfile_flags_t(COPYFILE_CLONE_FORCE))
    }
    if refused != 0 {
      log.notice(
        "\(resource.originalFilename, privacy: .private(mask: .hash)): no clone, error \(errno), so it is copied"
      )
      try? FileManager.default.removeItem(at: file)
    }
    return refused == 0
  }

  /// Places a copy of the resource, fetching it from iCloud when it is not on the device.
  private func copy(of resource: PHAssetResource, at file: URL) async throws {
    let needed = ResourceWeight(resource).bytes()
    let free = try store.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage ?? .max
    guard needed <= free else {
      throw NoRoomForCopy(name: resource.originalFilename, needed: needed, free: free)
    }
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    try await PHAssetResourceManager.default().writeData(
      for: resource,
      toFile: file,
      options: options
    )
  }

  private func bytes(at file: URL) -> Int64 {
    let facts = try? FileManager.default.attributesOfItem(atPath: file.path)
    return (facts?[.size] as? NSNumber)?.int64Value ?? -1
  }
}

/// The photo library as the place originals are removed from.
///
/// However many originals it is given, iOS asks the user to confirm once.
struct PhotoBin: Sendable {
  /// Removes from the library the originals whose copies are safe in the cloud.
  ///
  /// An original the library changed after its files were taken is left
  /// alone, because the cloud holds the earlier version of it.
  ///
  /// - Returns: The consignments whose originals were left for that reason.
  /// Removes the items from the library, of which no copy need exist anywhere.
  ///
  /// An item the library changed since the survey read it is left alone, as
  /// it is no longer the item the user looked at.
  ///
  /// - Returns: The items that were removed.
  func delete(_ items: [MediaItem]) async throws -> [MediaItem] {
    let found = PHAsset.fetchAssets(withLocalIdentifiers: items.map { $0.id }, options: nil)
    var changes: [String: Date] = [:]
    for index in 0..<found.count {
      let asset = found.object(at: index)
      changes[asset.localIdentifier] = asset.modificationDate ?? .distantPast
    }
    let going = items.filter { item in
      changes[item.id].map { item.unchanged(since: $0) } ?? false
    }
    let ids = going.map { $0.id }
    guard !ids.isEmpty else {
      return []
    }
    do {
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest.deleteAssets(
          PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        )
      }
    } catch let error as PHPhotosError where error.code == .userCancelled {
      throw DeletionDeclined()
    }
    return going
  }

  func discard(_ safe: [Consignment]) async throws -> [Consignment] {
    let found = PHAsset.fetchAssets(withLocalIdentifiers: safe.map { $0.id }, options: nil)
    var changes: [String: Date] = [:]
    for index in 0..<found.count {
      let asset = found.object(at: index)
      changes[asset.localIdentifier] = asset.modificationDate ?? .distantPast
    }
    let changed = safe.filter { consignment in
      changes[consignment.id].map { !consignment.unchanged(since: $0) } ?? false
    }
    let left = Set(changed.map { $0.id })
    let ids = safe.map { $0.id }.filter { changes[$0] != nil && !left.contains($0) }
    guard !ids.isEmpty else {
      return changed
    }
    do {
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest.deleteAssets(
          PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        )
      }
    } catch let error as PHPhotosError where error.code == .userCancelled {
      throw DeletionDeclined()
    }
    return changed
  }
}

/// The user answered iOS's question about deleting with "Don't Allow".
struct DeletionDeclined: LocalizedError {
  var errorDescription: String? {
    String(localized: "you chose not to delete")
  }
}

/// The photo library no longer has the asset.
struct MissingOriginal: LocalizedError {
  var errorDescription: String? {
    String(localized: "This item is no longer in the photo library")
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
    String(
      localized: "\(name) has to be copied before upload and needs \(needed.formatted(.byteCount(style: .file))), but this iPhone has only \(free.formatted(.byteCount(style: .file))) free"
    )
  }
}
