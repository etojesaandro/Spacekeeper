import Foundation
import Observation
import SpacekeeperCore
import UIKit
import os

/// The move of library items to the chosen cloud, as the screen follows it.
///
/// Items are laid ready and handed to the outbox, the system uploads them
/// whether the app is open or not, and those proven identical on the Disk
/// are then removed from the library with the user's consent.
@MainActor
@Observable
final class Uploads {
  /// What the screen has to show on top of everything else.
  enum Stage {
    case idle
    case working(headline: String, step: String)
    /// Something went wrong or needs the user's attention.
    case done(title: String, text: String)
    /// Something finished as asked.
    case told(title: String, text: String)
  }

  private(set) var stage = Stage.idle
  private(set) var queue: [Consignment] = []
  private(set) var sent: [String: Int64] = [:]
  @ObservationIgnored private var open = 0
  @ObservationIgnored private var quiet = false
  @ObservationIgnored private var owed: [() -> Void] = []
  @ObservationIgnored private var freeing = false
  @ObservationIgnored private var copied: [Consignment] = []
  private let outbox: Outbox
  private let staging: Staging
  private let bin: PhotoBin
  private let choice: Choice
  private let survey: Survey
  private let news: AsyncStream<TransitNews>
  private let log = Logger(subsystem: "Spacekeeper", category: "uploads")

  /// - Parameters:
  ///   - outbox: What remembers the items on their way.
  ///   - staging: What lays items ready for upload.
  ///   - bin: What removes originals from the library.
  ///   - choice: Which cloud items go to.
  ///   - survey: The ranking, told which items have left the library.
  ///   - news: What the system tells about the uploads.
  init(
    outbox: Outbox,
    staging: Staging,
    bin: PhotoBin,
    choice: Choice,
    survey: Survey,
    news: AsyncStream<TransitNews>
  ) {
    self.outbox = outbox
    self.staging = staging
    self.bin = bin
    self.choice = choice
    self.survey = survey
    self.news = news
  }

  /// Picks up what earlier launches left and starts listening to the system.
  func start() {
    Task {
      await outbox.tidy()
      await look()
      await wake()
    }
    Task {
      for await word in news {
        hear(word)
      }
    }
  }

  /// Looks where everything stands and moves it on; for when the app comes to the front.
  func wake() async {
    await outbox.advance()
    await look()
    told()
  }

  /// Looks again while the user is watching, and ends the move if that finished it.
  func tick() async {
    let before = travelling().count
    await wake()
    if before > 0 {
      await finish()
    }
  }

  /// The system woke the app to tell about uploads and wants to know when it has been heard.
  func woken(_ heard: @escaping () -> Void) {
    log.notice("woken by the system for finished uploads")
    owed.append(heard)
    Task {
      // The system allows about half a minute; what is not done by then waits.
      try? await Task.sleep(for: .seconds(20))
      repay()
    }
  }

  /// Lays the items ready and hands them to the outbox.
  ///
  /// - Parameters:
  ///   - items: What to upload.
  ///   - aim: Whether the items leave this iPhone once the Disk holds them.
  func begin(_ items: [MediaItem], aim: Aim) async {
    stage = .working(headline: String(localized: "Preparing"), step: "")
    guard choice.account().signedIn() else {
      stage = .done(
        title: String(localized: "Nothing was uploaded"),
        text: String(localized: "Connect \(cloud()) first, with the account button at the top.")
      )
      return
    }
    log.notice("begin \(items.count) items, \(items.reduce(0) { $0 + $1.bytes() }) bytes")
    var troubles: [String] = []
    for (index, item) in items.enumerated() {
      stage = .working(
        headline: items.count == 1
          ? item.name
          : String(localized: "\((index + 1).formatted()) of \(items.count.formatted()): \(item.name)"),
        step: String(localized: "Preparing for upload")
      )
      do {
        try await outbox.accept(try await staging.consignment(of: item, aim: aim))
      } catch {
        log.error("\(item.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        troubles.append("\(item.name): \(error.localizedDescription)")
      }
      await look()
    }
    stage = troubles.isEmpty
      ? .idle
      : .done(title: String(localized: "Not everything was queued"), text: troubles.joined(separator: "\n\n"))
  }

  /// Removes items from the library without copying them anywhere, with the user's consent.
  func delete(_ items: [MediaItem]) async {
    log.notice("asking to delete \(items.count) items of which no copy is made")
    do {
      let gone = try await bin.delete(items)
      survey.forget(gone)
      let size = gone.reduce(0) { $0 + $1.bytes() }.formatted(.byteCount(style: .file))
      let left = items.count - gone.count
      log.notice("deleted \(gone.count) items without a copy, left \(left)")
      let title = gone.isEmpty ? String(localized: "Nothing was deleted") : String(localized: "Deleted")
      var lines: [String] = []
      if gone.count == 1 {
        lines.append(
          String(
            localized: "\(gone[0].name), \(size), is in Recently Deleted on this iPhone. The space is freed once Recently Deleted is emptied."
          )
        )
      } else if gone.count > 1 {
        lines.append(
          String(
            localized: "\(gone.count) items, \(size), are in Recently Deleted on this iPhone. The space is freed once Recently Deleted is emptied."
          )
        )
      }
      if left > 0 {
        lines.append(
          String(
            localized: "\(left) items changed since the list was read and stayed. Pull down the library to read it again."
          )
        )
      }
      let text = lines.joined(separator: "\n\n")
      stage = left == 0 ? .told(title: title, text: text) : .done(title: title, text: text)
    } catch is DeletionDeclined {
      log.notice("the deletion was declined")
    } catch {
      log.error("deletion failed: \(error.localizedDescription, privacy: .public)")
      stage = .done(title: String(localized: "Nothing was deleted"), text: error.localizedDescription)
    }
  }

  /// Removes from the library the items whose copies are safe, with the user's consent.
  func free() async {
    let safe = safe()
    guard !freeing, !safe.isEmpty else {
      return
    }
    freeing = true
    defer {
      freeing = false
    }
    log.notice("asking to delete \(safe.count) items")
    do {
      let changed = try await bin.discard(safe)
      let left = Set(changed.map { $0.id })
      let gone = safe.filter { !left.contains($0.id) }
      await outbox.clear(Set(safe.map { $0.id }))
      survey.forget(gone.map { $0.original() })
      await look()
      var lines: [String] = []
      let size = gone.reduce(0) { $0 + $1.bytes() }.formatted(.byteCount(style: .file))
      if gone.count == 1 {
        lines.append(
          String(
            localized: "\(gone[0].original().name), \(size), is on \(cloud()) and in Recently Deleted on this iPhone. The space is freed once Recently Deleted is emptied."
          )
        )
      } else if gone.count > 1 {
        lines.append(
          String(
            localized: "\(gone.count) items, \(size), are on \(cloud()) and in Recently Deleted on this iPhone. The space is freed once Recently Deleted is emptied."
          )
        )
      }
      for consignment in changed {
        lines.append(
          String(
            localized: "\(consignment.original().name) was changed after it was uploaded, so it stays on this iPhone. Move it again to upload it as it is now."
          )
        )
      }
      log.notice("deleted \(gone.count) items, left \(changed.count) that changed")
      let title = gone.isEmpty ? String(localized: "Nothing was deleted") : String(localized: "Moved")
      let text = lines.joined(separator: "\n\n")
      stage = changed.isEmpty ? .told(title: title, text: text) : .done(title: title, text: text)
    } catch is DeletionDeclined {
      log.notice("the deletion was declined")
    } catch {
      log.error("deletion failed: \(error.localizedDescription, privacy: .public)")
      stage = .done(title: String(localized: "Nothing was deleted"), text: error.localizedDescription)
    }
  }

  /// Forgets the safe copies' items, which then stay on this iPhone as well.
  func keep() async {
    await outbox.clear(Set(safe().map { $0.id }))
    await look()
  }

  /// Sends again what could not be uploaded.
  func retry() async {
    await outbox.retry(Set(failed().map { $0.id }))
    await look()
  }

  /// Gives up what could not be uploaded; the items stay on this iPhone.
  func abandon() async {
    await outbox.clear(Set(failed().map { $0.id }))
    await look()
  }

  /// Calls off the uploads still going; the items stay on this iPhone.
  func cancel() async {
    await outbox.clear(Set(travelling().map { $0.id }))
    await look()
  }

  /// Puts a result away once the user has read it.
  func acknowledge() {
    stage = .idle
  }

  /// The name of the cloud items go to.
  func cloud() -> String {
    choice.account().name()
  }

  /// Items still being uploaded or verified.
  func travelling() -> [Consignment] {
    queue.filter { $0.standing() == .travelling }
  }

  /// Items whose copies are proven identical and that wait to be deleted.
  func safe() -> [Consignment] {
    queue.filter { $0.standing() == .safe && $0.leaves() }
  }

  /// Items that could not be uploaded.
  func failed() -> [Consignment] {
    queue.filter { $0.standing() != .travelling && $0.standing() != .safe }
  }

  /// Bytes of everything that is being uploaded or has been.
  func bytes() -> Int64 {
    (travelling() + safe()).reduce(0) { $0 + $1.bytes() }
  }

  /// How many of those bytes have reached the Disk.
  func gone() -> Int64 {
    (travelling() + safe()).reduce(0) { $0 + $1.gone(sent: sent) }
  }

  private func hear(_ word: TransitNews) {
    switch word {
    case .moved(let tag, let bytes):
      sent[tag] = bytes
    case .landed(let tag, let status):
      work { await $0.landed(tag, status: status) }
    case .lost(let tag, let reason):
      work { await $0.lost(tag, reason: reason) }
    case .dropped(let tag):
      work { await $0.dropped(tag) }
    case .quiet:
      quiet = true
      if open == 0 {
        repay()
      }
    }
  }

  /// Passes word to the outbox without holding up the news that follows.
  private func work(_ job: @escaping @Sendable (Outbox) async -> Void) {
    open += 1
    Task {
      await job(outbox)
      await look()
      open -= 1
      if quiet, open == 0 {
        repay()
      }
      await finish()
    }
  }

  /// Asks to delete once nothing travels any more, if the user is still here.
  ///
  /// The move the user confirmed ends with the deletion. Someone who comes
  /// back later is not met with iOS's question out of the blue, and finds a
  /// button instead.
  private func finish() async {
    guard !told(), open == 0, travelling().isEmpty, case .idle = stage,
      UIApplication.shared.applicationState == .active
    else {
      return
    }
    await free()
  }

  /// Tells of the copies made, once nothing travels any more.
  ///
  /// - Returns: Whether there was something to tell.
  @discardableResult
  private func told() -> Bool {
    guard !copied.isEmpty, travelling().isEmpty, case .idle = stage else {
      return false
    }
    let size = copied.reduce(0) { $0 + $1.bytes() }.formatted(.byteCount(style: .file))
    stage = .told(
      title: String(localized: "Copied"),
      text: copied.count == 1
        ? String(localized: "\(copied[0].original().name), \(size), is on \(cloud()) and still on this iPhone.")
        : String(localized: "\(copied.count) items, \(size), are on \(cloud()) and still on this iPhone.")
    )
    copied = []
    return true
  }

  /// Tells the system it has been heard.
  private func repay() {
    guard !owed.isEmpty else {
      return
    }
    quiet = false
    let heard = owed
    owed = []
    for answer in heard {
      answer()
    }
    log.notice("told the system its news was heard")
  }

  private func look() async {
    // A copy that has arrived is done with: its original stays where it is.
    let arrived = await outbox.consignments().filter { $0.standing() == .safe && !$0.leaves() }
    if !arrived.isEmpty {
      await outbox.clear(Set(arrived.map { $0.id }))
      copied += arrived
      log.notice("copied \(arrived.count) items, which stay on this iPhone")
    }
    let now = await outbox.consignments()
    if now != queue {
      queue = now
      let (travelling, safe, failed) = (travelling().count, safe().count, failed().count)
      log.notice("queue: \(travelling) travelling, \(safe) safe, \(failed) failed")
    }
  }
}
