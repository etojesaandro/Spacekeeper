import Foundation
import SpacekeeperCore
import Photos

/// The photo library of this device, read through PhotoKit.
struct DevicePhotos: Sendable {
  /// Asks the user for access; true when the library can be read.
  func opened() async -> Bool {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    return status == .authorized || status == .limited
  }

  /// Reads every photo and video together with its size.
  ///
  /// Asking PhotoKit for sizes is the slow part, so an item that is already
  /// known and has not changed since is taken as it is.
  ///
  /// - Parameters:
  ///   - known: Items read earlier, by identifier.
  ///   - progress: Told now and then how many items of how many are read.
  func items(
    known: [String: MediaItem],
    progress: @escaping @Sendable (Int, Int) -> Void
  ) async -> [MediaItem] {
    await Task.detached(priority: .userInitiated) {
      let assets = PHAsset.fetchAssets(with: PHFetchOptions())
      var items: [MediaItem] = []
      items.reserveCapacity(assets.count)
      for index in 0..<assets.count {
        autoreleasepool {
          let asset = assets.object(at: index)
          if let before = known[asset.localIdentifier],
            before.unchanged(since: asset.modificationDate ?? .distantPast)
          {
            items.append(before)
          } else {
            items.append(item(of: asset))
          }
        }
        if index % 100 == 0 {
          progress(index, assets.count)
        }
      }
      return items
    }.value
  }

  private func item(of asset: PHAsset) -> MediaItem {
    let weights = PHAssetResource.assetResources(for: asset).map(ResourceWeight.init)
    return MediaItem(
      id: asset.localIdentifier,
      name: weights.first?.name() ?? asset.localIdentifier,
      video: asset.mediaType == .video,
      seconds: asset.duration,
      created: asset.creationDate ?? .distantPast,
      modified: asset.modificationDate ?? .distantPast,
      size: weights.reduce(0) { $0 + $1.bytes() },
      local: weights.reduce(0) { $0 + ($1.local() ? $1.bytes() : 0) }
    )
  }
}

/// Size facts PhotoKit keeps about one stored file of an asset.
///
/// PhotoKit has no published way to learn a file's size without reading the
/// whole file, so this reads two properties that are not part of the public
/// API. If a future iOS drops them, sizes read as zero and everything counts
/// as on the device, rather than the app crashing.
struct ResourceWeight {
  private let resource: PHAssetResource

  init(_ resource: PHAssetResource) {
    self.resource = resource
  }

  func name() -> String {
    resource.originalFilename
  }

  func bytes() -> Int64 {
    guard resource.responds(to: NSSelectorFromString("fileSize")) else {
      return 0
    }
    return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
  }

  func local() -> Bool {
    guard resource.responds(to: NSSelectorFromString("isLocallyAvailable")) else {
      return true
    }
    return (resource.value(forKey: "locallyAvailable") as? NSNumber)?.boolValue ?? true
  }
}
