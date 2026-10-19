import Photos
import SwiftUI
import UIKit

/// Pictures of library items, as PhotoKit draws them at the size asked.
///
/// A quick, blurry picture comes first and a sharp one follows, so a grid
/// fills at once while the user scrolls. One manager serves the whole app,
/// which lets PhotoKit keep what it has drawn.
struct LibraryPictures: @unchecked Sendable {
  // PHCachingImageManager is documented as safe to use from any thread.
  private let manager: PHCachingImageManager

  init(manager: PHCachingImageManager) {
    self.manager = manager
  }

  /// The pictures of an item at the size given in pixels, blurry first, sharp last.
  ///
  /// - Parameter network: Whether a picture may come from iCloud when the phone has none.
  func pictures(of id: String, pixels: CGSize, network: Bool) -> AsyncStream<UIImage> {
    AsyncStream { continuation in
      let assets = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
      guard assets.count > 0 else {
        continuation.finish()
        return
      }
      let options = PHImageRequestOptions()
      options.deliveryMode = .opportunistic
      options.resizeMode = .fast
      options.isNetworkAccessAllowed = network
      let request = manager.requestImage(
        for: assets.object(at: 0),
        targetSize: pixels,
        contentMode: .aspectFill,
        options: options
      ) { @Sendable image, facts in
        // Marked sendable so it carries no main-thread requirement: PhotoKit
        // may answer on a thread of its own.
        if let image {
          continuation.yield(image)
        }
        let blurry = (facts?[PHImageResultIsDegradedKey] as? Bool) ?? false
        if !blurry || facts?[PHImageErrorKey] != nil {
          continuation.finish()
        }
      }
      continuation.onTermination = { [manager] _ in
        manager.cancelImageRequest(request)
      }
    }
  }
}

/// The one picture source the app's views share.
private struct PicturesKey: EnvironmentKey {
  // SwiftUI requires a static default; it is the single shared source.
  static let defaultValue = LibraryPictures(manager: PHCachingImageManager())
}

extension EnvironmentValues {
  /// Where views get pictures of library items.
  var pictures: LibraryPictures {
    get { self[PicturesKey.self] }
    set { self[PicturesKey.self] = newValue }
  }
}

/// A square picture of one library item, filling its frame.
struct LibraryPicture: View {
  private let id: String
  private let side: CGFloat
  @ViewState private var picture: [UIImage] = []
  @Environment(\.pictures) private var pictures
  @Environment(\.displayScale) private var scale

  /// - Parameters:
  ///   - id: The item's identifier in the photo library.
  ///   - side: The length of the square's side in points.
  init(id: String, side: CGFloat) {
    self.id = id
    self.side = side
  }

  var body: some View {
    Color(.secondarySystemFill)
      .overlay {
        if let picture = picture.first {
          // A filled picture reaches past the square; only the square takes touches.
          Image(uiImage: picture)
            .resizable()
            .scaledToFill()
            .allowsHitTesting(false)
        }
      }
      .frame(width: side, height: side)
      .clipped()
      .contentShape(Rectangle())
      // A new size draws the picture again, keeping the old one until the new one comes.
      .task(id: "\(id)@\(Int(side))") {
        let pixels = CGSize(width: side * scale, height: side * scale)
        for await image in pictures.pictures(of: id, pixels: pixels, network: false) {
          picture = [image]
        }
      }
  }
}
