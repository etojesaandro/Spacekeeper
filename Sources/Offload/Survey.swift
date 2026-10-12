import Foundation
import Observation
import OffloadCore
import os

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
    /// Every item of the library, biggest first.
    let items: [MediaItem]
    let total: Int64
    let onDevice: Int64
    let seconds: Double
    /// The years and months the items come from.
    let spans: [Span]
    let period: Period
    let order: Order
    /// The items of the chosen period, in the chosen order.
    let listed: [MediaItem]

    /// The same findings listed for another period, in another order.
    func arranged(for period: Period, by order: Order) -> Findings {
      Findings(
        items: items,
        total: total,
        onDevice: onDevice,
        seconds: seconds,
        spans: spans,
        period: period,
        order: order,
        listed: Almanac(items, calendar: .current).items(of: period, by: order)
      )
    }
  }

  private(set) var stage = Stage.waiting
  private let photos: DevicePhotos
  private let remembered: RememberedItems

  /// - Parameters:
  ///   - photos: The library to read.
  ///   - remembered: Where items are kept between launches.
  init(photos: DevicePhotos, remembered: RememberedItems) {
    self.photos = photos
    self.remembered = remembered
  }

  /// Asks for access, reads the library and ranks it, reusing what is remembered.
  ///
  /// Whether an item's original is on the device can change without the
  /// item itself changing, so remembered iCloud marks may be out of date
  /// until `afresh()` reads everything again.
  func run() async {
    let remembered = self.remembered
    await read(known: await Task.detached { remembered.items() }.value)
  }

  /// Reads every item again, trusting nothing remembered.
  func afresh() async {
    await read(known: [:])
  }

  /// Drops items that have left the library, without reading everything again.
  func forget(_ gone: [MediaItem]) {
    guard case .ranked(let findings) = stage, !gone.isEmpty else {
      return
    }
    let left = Set(gone.map { $0.id })
    stage = .ranked(
      found(
        findings.items.filter { !left.contains($0.id) },
        seconds: findings.seconds,
        period: findings.period,
        order: findings.order
      )
    )
  }

  /// Lists the items of a period, in an order.
  func arrange(for period: Period, by order: Order) {
    if case .ranked(let findings) = stage {
      stage = .ranked(findings.arranged(for: period, by: order))
    }
  }

  private func found(
    _ items: [MediaItem],
    seconds: Double,
    period: Period,
    order: Order
  ) -> Findings {
    let ranking = BiggestFirst(items)
    let almanac = Almanac(items, calendar: .current)
    return Findings(
      items: ranking.ranked(),
      total: ranking.total(),
      onDevice: ranking.onDevice(),
      seconds: seconds,
      spans: almanac.spans(),
      period: period,
      order: order,
      listed: almanac.items(of: period, by: order)
    )
  }

  private func read(known: [String: MediaItem]) async {
    guard await photos.opened() else {
      stage = .refused
      return
    }
    // Reading again keeps the period and the order the user has chosen.
    var period = Period.always
    var order = Order.biggest
    if case .ranked(let before) = stage {
      (period, order) = (before.period, before.order)
    }
    stage = .reading(done: 0, of: 0)
    let started = Date()
    let items = await photos.items(known: known) { done, of in
      Task { @MainActor in
        self.noted(done: done, of: of)
      }
    }
    let seconds = Date().timeIntervalSince(started)
    stage = .ranked(found(items, seconds: seconds, period: period, order: order))
    let same = items.filter { known[$0.id] == $0 }.count
    Logger(subsystem: "Offload", category: "survey").notice(
      "read \(items.count) items in \(seconds, format: .fixed(precision: 1)) s, \(same) remembered"
    )
    let remembered = self.remembered
    Task.detached(priority: .utility) {
      // Failing to remember only makes the next reading slower.
      try? remembered.keep(items)
    }
  }

  private func noted(done: Int, of: Int) {
    // A late progress note must not replace a finished ranking.
    if case .reading = stage {
      stage = .reading(done: done, of: of)
    }
  }
}
