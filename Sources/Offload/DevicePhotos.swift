import Foundation
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
  /// - Parameter progress: Told now and then how many items of how many are read.
  func items(progress: @escaping @Sendable (Int, Int) -> Void) async -> [LibraryItem] {
    await Task.detached(priority: .userInitiated) {
      let assets = PHAsset.fetchAssets(with: PHFetchOptions())
      var items: [LibraryItem] = []
      items.reserveCapacity(assets.count)
      for index in 0..<assets.count {
        autoreleasepool {
          items.append(item(of: assets.object(at: index)))
        }
        if index % 100 == 0 {
          progress(index, assets.count)
        }
      }
      return items
    }.value
  }

  private func item(of asset: PHAsset) -> LibraryItem {
    let weights = PHAssetResource.assetResources(for: asset).map(ResourceWeight.init)
    return LibraryItem(
      id: asset.localIdentifier,
      name: weights.first?.name() ?? asset.localIdentifier,
      video: asset.mediaType == .video,
      seconds: asset.duration,
      created: asset.creationDate ?? .distantPast,
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
private struct ResourceWeight {
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
