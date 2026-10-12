import Photos
import SwiftUI
import UIKit

/// A small square picture of one library item.
struct Thumbnail: View {
  private let id: String
  private let side: CGFloat
  @ViewState private var picture = Image(systemName: "photo")
  @ViewState private var loaded = false

  init(id: String, side: CGFloat) {
    self.id = id
    self.side = side
  }

  var body: some View {
    picture
      .resizable()
      .aspectRatio(contentMode: loaded ? .fill : .fit)
      .foregroundStyle(.tertiary)
      .frame(width: side, height: side)
      .background(.quaternary)
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .task(id: id) {
        for image in await images() {
          picture = Image(uiImage: image)
          loaded = true
        }
      }
  }

  /// The picture PhotoKit has on the device for this item; empty when it has none.
  private func images() async -> [UIImage] {
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
    guard assets.count > 0 else {
      return []
    }
    let options = PHImageRequestOptions()
    // With this mode PhotoKit answers exactly once, which the continuation requires.
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .fast
    let scale = UIScreen.main.scale
    return await withCheckedContinuation { continuation in
      PHImageManager.default().requestImage(
        for: assets.object(at: 0),
        targetSize: CGSize(width: side * scale, height: side * scale),
        contentMode: .aspectFill,
        options: options
      ) { @Sendable image, _ in
        // Marked sendable so it carries no main-thread requirement: PhotoKit
        // may answer on a thread of its own.
        continuation.resume(returning: image.map { [$0] } ?? [])
      }
    }
  }
}
