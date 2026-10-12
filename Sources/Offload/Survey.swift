import Foundation
import Observation
import OffloadCore

/// A survey of the photo library: what is in it and how much space each item takes.
@MainActor
@Observable
final class Survey {
  /// Where the survey stands.
  enum Stage {
    case waiting
    case refused
    case reading(done: Int, of: Int)
    case ranked(Findings)
  }

  /// What a finished survey found.
  struct Findings {
    let items: [LibraryItem]
    let total: Int64
    let onDevice: Int64
    let seconds: Double
  }

  private(set) var stage = Stage.waiting
  private let photos: DevicePhotos

  init(photos: DevicePhotos) {
    self.photos = photos
  }

  /// Asks for access, reads the library and ranks it.
  func run() async {
    guard await photos.opened() else {
      stage = .refused
      return
    }
    stage = .reading(done: 0, of: 0)
    let started = Date()
    let items = await photos.items { done, of in
      Task { @MainActor in
        self.noted(done: done, of: of)
      }
    }
    let ranking = BiggestFirst(items)
    stage = .ranked(
      Findings(
        items: ranking.ranked(),
        total: ranking.total(),
        onDevice: ranking.onDevice(),
        seconds: Date().timeIntervalSince(started)
      )
    )
  }

  /// Drops an item that has left the library, without reading everything again.
  func forget(_ item: LibraryItem) {
    guard case .ranked(let findings) = stage else {
      return
    }
    let ranking = BiggestFirst(findings.items.filter { $0.id != item.id })
    stage = .ranked(
      Findings(
        items: ranking.ranked(),
        total: ranking.total(),
        onDevice: ranking.onDevice(),
        seconds: findings.seconds
      )
    )
  }

  private func noted(done: Int, of: Int) {
    // A late progress note must not replace a finished ranking.
    if case .reading = stage {
      stage = .reading(done: done, of: of)
    }
  }
}
