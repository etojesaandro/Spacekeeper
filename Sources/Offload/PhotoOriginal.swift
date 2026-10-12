import Foundation
import OffloadCore
import Photos

/// An original of the photo library, addressed by its PhotoKit identifier.
///
/// Every file PhotoKit stores for it is copied into a folder the caller owns
/// and is expected to delete afterwards.
struct PhotoOriginal: Original {
  private let id: String
  private let folder: URL

  /// - Parameters:
  ///   - id: PhotoKit local identifier of the asset.
  ///   - folder: Where its files are copied to for the upload.
  init(id: String, folder: URL) {
    self.id = id
    self.folder = folder
  }

  func parts() async throws -> [Part] {
    let found = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
    guard found.count > 0 else {
      throw MissingOriginal()
    }
    let asset = found.object(at: 0)
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let prefix = "\(stamp(asset))_\(id.prefix(8))"
    var parts: [Part] = []
    for (index, resource) in PHAssetResource.assetResources(for: asset).enumerated() {
      let file = folder.appendingPathComponent("\(index)-\(resource.originalFilename)")
      try await PHAssetResourceManager.default().writeData(
        for: resource,
        toFile: file,
        options: options
      )
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

/// The photo library no longer has the asset.
struct MissingOriginal: LocalizedError {
  var errorDescription: String? {
    "This item is no longer in the photo library"
  }
}
