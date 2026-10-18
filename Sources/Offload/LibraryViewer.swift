import AVKit
import OffloadCore
import Photos
import SwiftUI
import UIKit

/// Library items looked through one by one, with what can be done to the one on screen.
struct LibraryViewer: View {
  private let items: [MediaItem]
  private let start: String
  private let uploads: Uploads
  private let cloud: String
  private let act: (Deed, MediaItem) -> Void
  @Environment(\.dismiss) private var dismiss

  /// - Parameters:
  ///   - items: The items to look through, in order.
  ///   - start: The identifier of the item shown first.
  ///   - uploads: The move of items to the cloud, which tells what is on its way.
  ///   - cloud: The name of the cloud items go to.
  ///   - act: Told what the user decided to do with an item.
  init(
    items: [MediaItem],
    start: String,
    uploads: Uploads,
    cloud: String,
    act: @escaping (Deed, MediaItem) -> Void
  ) {
    self.items = items
    self.start = start
    self.uploads = uploads
    self.cloud = cloud
    self.act = act
  }

  var body: some View {
    Pager(
      items: items,
      start: start,
      heading: { item in
        (
          item.created.formatted(date: .abbreviated, time: .omitted),
          "\(item.created.formatted(date: .omitted, time: .shortened)) · "
            + item.bytes().formatted(.byteCount(style: .file))
        )
      },
      page: { item, shown in
        LibraryPage(item: item, shown: shown)
      },
      bar: { item in
        actions(for: item)
      },
      info: facts
    )
  }

  @ViewBuilder private func actions(for item: MediaItem) -> some View {
    if uploads.queue.contains(where: { $0.id == item.id }) {
      Label("On its way to \(cloud)", systemImage: "arrow.up.circle.fill")
        .font(.subheadline.weight(.semibold))
        .frame(maxWidth: .infinity, minHeight: 44)
    } else {
      HStack(spacing: 10) {
        Button(role: .destructive) {
          dismiss()
          act(.delete, item)
        } label: {
          Image(systemName: "trash")
            .frame(minWidth: 44, minHeight: 30)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Delete without a copy")
        Button {
          act(.copy, item)
        } label: {
          Label("Copy", systemImage: "doc.on.doc")
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.bordered)
        Button {
          act(.move, item)
        } label: {
          Label("Move to \(cloud)", systemImage: "icloud.and.arrow.up")
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.borderedProminent)
      }
      .controlSize(.large)
    }
  }

  private func facts(_ item: MediaItem) -> [Fact] {
    var facts = [
      Fact(name: "Kind", value: item.video ? "Video" : "Photo"),
      Fact(name: "File", value: item.name),
      Fact(name: "Taken", value: item.created.formatted(date: .long, time: .shortened)),
      Fact(name: "Size", value: item.bytes().formatted(.byteCount(style: .file))),
    ]
    if item.video {
      facts.append(
        Fact(
          name: "Length",
          value: Duration.seconds(item.seconds.rounded()).formatted(.time(pattern: .minuteSecond))
        )
      )
    }
    facts.append(
      Fact(
        name: "On this iPhone",
        value: item.onDevice() >= item.bytes()
          ? "Yes"
          : item.onDevice() == 0
            ? "No, only in iCloud"
            : "\(item.onDevice().formatted(.byteCount(style: .file))) of it"
      )
    )
    return facts
  }
}

/// One library item filling the screen: a photo to zoom, a Live Photo, or a video to play.
struct LibraryPage: View {
  private let item: MediaItem
  private let shown: Bool
  @ViewState private var pictures: [UIImage] = []
  @ViewState private var lives: [PHLivePhoto] = []
  @ViewState private var players: [AVPlayer] = []
  @ViewState private var blank = false
  @Environment(\.pictures) private var source
  @Environment(\.displayScale) private var scale

  init(item: MediaItem, shown: Bool) {
    self.item = item
    self.shown = shown
  }

  var body: some View {
    Group {
      if let player = players.first {
        Screening(player: player)
      } else if let live = lives.first {
        LivePicture(photo: live)
      } else if let picture = pictures.first {
        ZoomingPicture(image: picture)
      } else if blank {
        ContentUnavailableView(
          "No preview",
          systemImage: "eye.slash",
          description: Text("Photos could not show this item.")
        )
      } else {
        ProgressView()
      }
    }
    .task {
      await load()
    }
    .onChange(of: shown) { _, now in
      if !now {
        players.first?.pause()
      }
    }
    .onDisappear {
      players.first?.pause()
    }
  }

  private func load() async {
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil)
    guard assets.count > 0 else {
      blank = true
      return
    }
    let asset = assets.object(at: 0)
    let screen = UIScreen.main.bounds.size
    let pixels = CGSize(width: screen.width * scale, height: screen.height * scale)
    if item.video {
      players = await video(of: asset).map { AVPlayer(playerItem: AVPlayerItem(asset: $0.asset)) }
      blank = players.isEmpty
      return
    }
    // The still comes first, so there is something to see while the Live Photo loads.
    for await image in source.pictures(of: item.id, pixels: pixels, network: true) {
      pictures = [image]
    }
    if asset.mediaSubtypes.contains(.photoLive) {
      lives = await live(of: asset, pixels: pixels)
    }
    blank = pictures.isEmpty && lives.isEmpty
  }

  /// The video as PhotoKit plays it, with any edits; empty when it cannot be had.
  private func video(of asset: PHAsset) async -> [LentVideo] {
    let options = PHVideoRequestOptions()
    options.deliveryMode = .automatic
    options.isNetworkAccessAllowed = true
    return await withCheckedContinuation { continuation in
      PHImageManager.default().requestAVAsset(forVideo: asset, options: options) {
        @Sendable video, _, _ in
        continuation.resume(returning: video.map { [LentVideo(asset: $0)] } ?? [])
      }
    }
  }

  /// The Live Photo at the size of the screen; empty when it cannot be had.
  private func live(of asset: PHAsset, pixels: CGSize) async -> [PHLivePhoto] {
    let options = PHLivePhotoRequestOptions()
    // With this mode PhotoKit answers exactly once, which the continuation requires.
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = true
    return await withCheckedContinuation { continuation in
      PHImageManager.default().requestLivePhoto(
        for: asset,
        targetSize: pixels,
        contentMode: .aspectFit,
        options: options
      ) { @Sendable photo, _ in
        continuation.resume(returning: photo.map { [$0] } ?? [])
      }
    }
  }
}

/// A video PhotoKit handed over on a thread of its own.
///
/// The compiler cannot see that an `AVAsset` may cross threads, though
/// AVFoundation documents it as safe to read from any; this says so.
private struct LentVideo: @unchecked Sendable {
  let asset: AVAsset
}

/// What the user decides to do with library items.
enum Deed {
  /// Upload, verify, then delete from this iPhone.
  case move

  /// Upload and keep on this iPhone as well.
  case copy

  /// Delete from this iPhone without a copy.
  case delete
}
