import Foundation
import Observation
import OffloadCore
import os

/// The move of library items to Yandex Disk, as the screen follows it.
@MainActor
@Observable
final class Relocation {
  /// Where the move stands.
  enum Stage {
    case idle
    case working(headline: String, step: String)
    case done(title: String, text: String)
  }

  private(set) var stage = Stage.idle
  private let token: KeychainToken
  private let session: URLSession

  /// - Parameters:
  ///   - token: Where the Yandex Disk token is kept.
  ///   - session: Session the uploads go through.
  init(token: KeychainToken, session: URLSession) {
    self.token = token
    self.session = session
  }

  /// Uploads the items, verifies the copies and removes the originals together.
  ///
  /// - Returns: The items that have left the photo library.
  func run(_ items: [MediaItem]) async -> [MediaItem] {
    stage = .working(headline: "Preparing", step: "")
    let log = Logger(subsystem: "Offload", category: "move")
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("offload-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: folder)
    }
    let vigil = Vigil()
    vigil.begin()
    defer {
      vigil.end()
    }
    let say: @Sendable (String) -> Void = { text in
      log.notice("\(text, privacy: .public)")
      Task { @MainActor in
        self.noted(step: text)
      }
    }
    let secret: String
    do {
      secret = try token.value()
    } catch {
      stage = .done(title: "Nothing was deleted", text: error.localizedDescription)
      return []
    }
    log.notice("begin \(items.count) items, \(items.reduce(0) { $0 + $1.bytes() }) bytes")
    let api = YandexApi(token: secret, wire: PatientWire(session: session, say: say))
    let fates = await Sweep(
      of: items.enumerated().map { index, item in
        PhotoOriginal(id: item.id, folder: folder.appendingPathComponent("\(index)"))
      },
      to: NarratedCloud(WithinAllowance(YandexDisk(api: api), api: api), say: say),
      into: PhotoBin(),
      watched: Announcer(names: items.map { $0.name }) { headline in
        log.notice("\(headline, privacy: .public)")
        Task { @MainActor in
          self.noted(headline: headline)
        }
      }
    ).run()
    let report = Report(items: items, fates: fates)
    log.notice("end: \(report.title(), privacy: .public). \(report.text(), privacy: .public)")
    stage = .done(title: report.title(), text: report.text())
    return report.moved()
  }

  /// Puts the result away once the user has read it.
  func acknowledge() {
    stage = .idle
  }

  // A late note must not replace the result.
  private func noted(headline: String) {
    if case .working = stage {
      stage = .working(headline: headline, step: "")
    }
  }

  private func noted(step: String) {
    if case .working(let headline, _) = stage {
      stage = .working(headline: headline, step: step)
    }
  }
}

/// An onlooker that puts a sweep's progress into a line for the screen.
private struct Announcer: Onlooker {
  private let names: [String]
  private let say: @Sendable (String) -> Void

  init(names: [String], say: @escaping @Sendable (String) -> Void) {
    self.names = names
    self.say = say
  }

  func copying(_ number: Int, of count: Int) {
    say(count == 1 ? names[number - 1] : "\(number) of \(count): \(names[number - 1])")
  }

  func discarding(_ count: Int) {
    say(
      count == 1
        ? "Waiting for your permission to delete"
        : "Waiting for your permission to delete \(count) items"
    )
  }
}

/// What a finished sweep did, in words for the user.
private struct Report {
  private let items: [MediaItem]
  private let fates: [Fate]

  init(items: [MediaItem], fates: [Fate]) {
    self.items = items
    self.fates = fates
  }

  /// The items that have left the photo library.
  func moved() -> [MediaItem] {
    zip(items, fates).filter { $0.1 == .moved }.map { $0.0 }
  }

  func title() -> String {
    let count = moved().count
    if count == items.count {
      return "Moved"
    }
    return count == 0 ? "Nothing was deleted" : "Moved \(count) of \(items.count)"
  }

  func text() -> String {
    let count = moved().count
    var lines: [String] = []
    if count == 1 {
      lines.append(
        "\(moved()[0].name) is on Yandex Disk and in Recently Deleted on this iPhone. "
          + "Its space is freed once Recently Deleted is emptied."
      )
    } else if count > 1 {
      lines.append(
        "\(count) items are on Yandex Disk and in Recently Deleted on this iPhone. "
          + "Their space is freed once Recently Deleted is emptied."
      )
    }
    let copied = zip(items, fates).filter {
      if case .copied = $0.1 {
        return true
      }
      return false
    }
    if copied.count > 1, Set(copied.map { $0.1 }).count == 1, case .copied(let reason) = copied[0].1 {
      lines.append(
        "\(copied.count) items are on Yandex Disk but still on this iPhone: \(reason)"
      )
    } else {
      for case (let item, .copied(let reason)) in copied {
        lines.append("\(item.name) is on Yandex Disk but still on this iPhone: \(reason)")
      }
    }
    for case (let item, .kept(let reason)) in zip(items, fates) {
      lines.append("\(item.name) was not uploaded: \(reason)")
    }
    return lines.joined(separator: "\n\n")
  }
}
