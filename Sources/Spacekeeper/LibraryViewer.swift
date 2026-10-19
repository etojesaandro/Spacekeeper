import AVKit
import SpacekeeperCore
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
      bar: { item, inform in
        actions(for: item, inform: inform)
      },
      info: facts
    )
    .onAppear {
      Loudspeaker().open()
    }
    .onDisappear {
      Loudspeaker().close()
    }
  }

  @ViewBuilder private func actions(for item: MediaItem, inform: @escaping () -> Void) -> some View {
    ActionBar {
      if let consignment = uploads.queue.first(where: { $0.id == item.id }) {
        ItemTransfer(consignment: consignment, sent: uploads.sent, cloud: cloud)
      } else if case .working(_, let step) = uploads.stage {
        // The item is being laid ready; the queue does not know it yet.
        HStack(spacing: 10) {
          ProgressView()
          Text(step.isEmpty ? String(localized: "Preparing") : step)
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 44)
      } else {
        ActionButton("Delete", symbol: "trash", tint: .red, spoken: String(localized: "Delete without a copy")) {
          dismiss()
          act(.delete, item)
        }
        ActionButton("Copy", symbol: "doc.on.doc", tint: .primary, spoken: String(localized: "Copy to \(cloud)")) {
          act(.copy, item)
        }
        ActionButton("Move", symbol: "icloud.and.arrow.up.fill", spoken: String(localized: "Move to \(cloud)")) {
          act(.move, item)
        }
      }
      ActionButton("Info", symbol: "info.circle", tint: .primary, action: inform)
    }
  }

  private func facts(_ item: MediaItem) -> [Fact] {
    var facts = [
      Fact(name: String(localized: "Kind"), value: item.video ? String(localized: "Video") : String(localized: "Photo")),
      Fact(name: String(localized: "File"), value: item.name),
      Fact(name: String(localized: "Taken"), value: item.created.formatted(date: .long, time: .shortened)),
      Fact(name: String(localized: "Size"), value: item.bytes().formatted(.byteCount(style: .file))),
    ]
    if item.video {
      facts.append(
        Fact(
          name: String(localized: "Length"),
          value: Duration.seconds(item.seconds.rounded()).formatted(.time(pattern: .minuteSecond))
        )
      )
    }
    facts.append(
      Fact(
        name: String(localized: "On this iPhone"),
        value: item.onDevice() >= item.bytes()
          ? String(localized: "Yes")
          : item.onDevice() == 0
            ? String(localized: "No, only in iCloud")
            : String(localized: "\(item.onDevice().formatted(.byteCount(style: .file))) of it")
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
      // Like Photos, a video plays when it comes on screen and stops when it leaves.
      if now {
        players.first?.play()
      } else {
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
      if shown {
        players.first?.play()
      }
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

/// The phone's sound while the user watches: on even with the switch set to silent, as in Photos.
///
/// Someone who opens a video means to hear it. While the viewer is open the
/// app plays like a video player; once it closes, other apps' sound, such as
/// music that was paused, comes back.
struct Loudspeaker {
  func open() {
    let session = AVAudioSession.sharedInstance()
    // Failing only leaves the sound to follow the switch, as before.
    try? session.setCategory(.playback, mode: .moviePlayback)
    try? session.setActive(true)
  }

  func close() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}

/// How far one item's move or copy has got, for the viewer that covers the transfers strip.
struct ItemTransfer: View {
  let consignment: Consignment
  let sent: [String: Int64]
  let cloud: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      switch consignment.standing() {
      case .travelling:
        let gone = min(consignment.gone(sent: sent), consignment.bytes())
        Label(
          String(localized: "Uploading to \(cloud)"),
          systemImage: "arrow.up.circle.fill"
        )
        .font(.subheadline.weight(.semibold))
        ProgressView(value: Double(gone), total: Double(max(consignment.bytes(), 1)))
        Text(
          String(
            localized: "\(gone.formatted(.byteCount(style: .file))) of \(consignment.bytes().formatted(.byteCount(style: .file)))"
          )
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      case .safe:
        Label(String(localized: "Safe on \(cloud)"), systemImage: "checkmark.icloud.fill")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.green)
        Text("Checked against the original. Free up the space from the transfers strip.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      case .failed(let reason):
        Label("Not uploaded", systemImage: "exclamationmark.triangle.fill")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.orange)
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 8)
    .accessibilityElement(children: .combine)
  }
}
