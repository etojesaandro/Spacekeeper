import AVKit
import OffloadCore
import Photos
import SwiftUI
import UIKit

/// One library item seen large, with the way to move it to Yandex Disk.
///
/// A photo is shown, a video can be played. What is only in iCloud is
/// fetched for the look, which may take a moment.
struct Closeup: View {
  private let item: MediaItem
  private let away: Bool
  private let move: () -> Void
  @ViewState private var pictures: [UIImage] = []
  @ViewState private var players: [AVPlayer] = []
  @ViewState private var blank = false
  @Environment(\.dismiss) private var dismiss

  /// - Parameters:
  ///   - item: The item to show.
  ///   - away: Whether it is already on its way to the cloud.
  ///   - move: Called when the user decides to move it.
  init(item: MediaItem, away: Bool, move: @escaping () -> Void) {
    self.item = item
    self.away = away
    self.move = move
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        media
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.black)
        VStack(alignment: .leading, spacing: 10) {
          Text(detail)
            .font(.subheadline)
          if item.onDevice() < item.bytes() {
            Label(
              item.onDevice() == 0 ? "Only in iCloud" : "Partly in iCloud",
              systemImage: "icloud"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          if away {
            Label("On its way to Yandex Disk", systemImage: "arrow.up.circle.fill")
              .font(.subheadline.weight(.semibold))
          } else {
            Button {
              dismiss()
              move()
            } label: {
              Text("Upload, verify, then delete")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text(
              "The upload goes on if you leave the app. Nothing is deleted from this iPhone "
                + "until Yandex Disk confirms an identical copy, and iOS will ask you to "
                + "confirm the deletion."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        .padding()
      }
      .navigationTitle(item.name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
      .task {
        await load()
      }
      .onDisappear {
        players.first?.pause()
      }
    }
  }

  @ViewBuilder private var media: some View {
    if let player = players.first {
      Screening(player: player)
    } else if let picture = pictures.first {
      Image(uiImage: picture)
        .resizable()
        .scaledToFit()
    } else if blank {
      ContentUnavailableView(
        "No preview",
        systemImage: "eye.slash",
        description: Text("The photo library could not show this item.")
      )
    } else {
      ProgressView()
        .tint(.white)
    }
  }

  private var detail: String {
    let date = item.created.formatted(date: .abbreviated, time: .shortened)
    let size = item.bytes().formatted(.byteCount(style: .file))
    guard item.video else {
      return "Photo · \(size) · \(date)"
    }
    let length = Duration.seconds(item.seconds.rounded())
      .formatted(.time(pattern: .minuteSecond))
    return "Video · \(length) · \(size) · \(date)"
  }

  private func load() async {
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: [item.id], options: nil)
    guard assets.count > 0 else {
      blank = true
      return
    }
    if item.video {
      players = await video(of: assets.object(at: 0)).map {
        AVPlayer(playerItem: AVPlayerItem(asset: $0.asset))
      }
      blank = players.isEmpty
    } else {
      pictures = await picture(of: assets.object(at: 0))
      blank = pictures.isEmpty
    }
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

  /// The photo at the size of the screen; empty when it cannot be had.
  private func picture(of asset: PHAsset) async -> [UIImage] {
    let options = PHImageRequestOptions()
    // With this mode PhotoKit answers exactly once, which the continuation requires.
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = true
    let screen = UIScreen.main.bounds.size
    let scale = UIScreen.main.scale
    return await withCheckedContinuation { continuation in
      PHImageManager.default().requestImage(
        for: asset,
        targetSize: CGSize(width: screen.width * scale, height: screen.height * scale),
        contentMode: .aspectFit,
        options: options
      ) { @Sendable image, _ in
        continuation.resume(returning: image.map { [$0] } ?? [])
      }
    }
  }
}

/// The system's video player with its usual controls.
private struct Screening: UIViewControllerRepresentable {
  private let player: AVPlayer

  init(player: AVPlayer) {
    self.player = player
  }

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let screen = AVPlayerViewController()
    screen.player = player
    return screen
  }

  func updateUIViewController(_ screen: AVPlayerViewController, context: Context) {
    screen.player = player
  }
}

/// A video PhotoKit handed over on a thread of its own.
///
/// The compiler cannot see that an `AVAsset` may cross threads, though
/// AVFoundation documents it as safe to read from any; this says so.
private struct LentVideo: @unchecked Sendable {
  let asset: AVAsset
}
