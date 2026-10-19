import Foundation
import Network
import Observation
import SpacekeeperCore
import Photos
import UIKit
import os

/// The backup of the photo library to a computer over the cable, as the screen follows it.
///
/// While it is open, a computer this iPhone trusts can read the library
/// through the cable, if it knows the code shown on the screen. Nothing is
/// reachable from the network, and nothing at all once it is closed.
@MainActor
@Observable
final class CableBackup {
  /// The code a computer must give; empty while the backup is closed.
  private(set) var code = ""
  /// How many files have gone to the computer since the backup was opened.
  private(set) var files = 0
  /// How many bytes those files had together.
  private(set) var bytes: Int64 = 0
  /// The items the computer says it safely holds.
  private(set) var held: [MediaItem] = []
  /// What went wrong or what was done last, in words for the user; empty for nothing.
  private(set) var note = ""
  @ObservationIgnored private var listeners: [NWListener] = []
  private let stock: PhotoStock
  private let bin: PhotoBin
  private let survey: Survey
  private let news: AsyncStream<CableNews>
  private let port: UInt16
  private let log = Logger(subsystem: "Spacekeeper", category: "cable")

  /// - Parameters:
  ///   - stock: What is handed out of the photo library.
  ///   - bin: What removes originals from the library.
  ///   - survey: The library survey, told which items have left the library.
  ///   - news: What the stock tells about what it hands out.
  ///   - port: The port a computer reaches through the cable.
  init(
    stock: PhotoStock,
    bin: PhotoBin,
    survey: Survey,
    news: AsyncStream<CableNews>,
    port: UInt16
  ) {
    self.stock = stock
    self.bin = bin
    self.survey = survey
    self.news = news
    self.port = port
  }

  /// Starts listening to what the stock tells.
  func start() {
    Task {
      for await word in news {
        switch word {
        case .poured(let count):
          files += 1
          bytes += count
        case .held(let ids):
          note(holding: ids)
        }
      }
    }
  }

  /// Opens the library to a computer, under a fresh code.
  func open() {
    close()
    files = 0
    bytes = 0
    held = []
    note = ""
    let fresh = String(format: "%06d", Int.random(in: 0..<1_000_000))
    do {
      listeners = [try Hatchway(hatch: Hatch(stock: stock, code: fresh), port: port).opened()]
      code = fresh
      UIApplication.shared.isIdleTimerDisabled = true
      log.notice("the library is open to a computer over the cable")
    } catch {
      note = String(localized: "The backup could not be opened: \(error.localizedDescription)")
      log.error("not opened: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Closes the library to computers.
  func close() {
    for listener in listeners {
      listener.cancel()
    }
    if !listeners.isEmpty {
      UIApplication.shared.isIdleTimerDisabled = false
      log.notice("the library is closed to computers, after \(self.files) files")
    }
    listeners = []
    code = ""
  }

  /// Removes from the library the items the computer holds, with the user's consent.
  func free() async {
    let going = held
    guard !going.isEmpty else {
      return
    }
    log.notice("asking to delete \(going.count) items the computer holds")
    do {
      let gone = try await bin.delete(going)
      survey.forget(gone)
      held = []
      let size = gone.reduce(0) { $0 + $1.bytes() }.formatted(.byteCount(style: .file))
      let left = going.count - gone.count
      note = String(
        localized: "\(gone.count) items, \(size), are on the computer and in Recently Deleted on this iPhone. The space is freed once Recently Deleted is emptied."
      )
        + (left == 0 ? "" : " " + String(localized: "\(left) items changed since they were listed and stayed."))
      log.notice("deleted \(gone.count) items the computer holds, left \(left)")
    } catch is DeletionDeclined {
      log.notice("the deletion was declined")
    } catch {
      note = String(localized: "Nothing was deleted: \(error.localizedDescription)")
    }
  }

  private func note(holding ids: [String]) {
    guard case .ranked(let findings) = survey.stage else {
      return
    }
    let known = Set(held.map { $0.id })
    let named = Set(ids).subtracting(known)
    held += findings.items.filter { named.contains($0.id) }
    log.notice("the computer holds \(self.held.count) items")
  }
}

/// What the stock tells about what it hands out.
enum CableNews: Sendable {
  /// A whole file of this many bytes has gone out.
  case poured(Int64)

  /// A computer says it safely holds the items with these identifiers.
  case held([String])
}

/// The photo library of this device as what a computer may fetch.
struct PhotoStock: Stock {
  private let survey: Survey
  private let news: AsyncStream<CableNews>.Continuation

  /// - Parameters:
  ///   - survey: The library survey, whose items are the ones offered.
  ///   - news: Where it tells what it has handed out.
  init(survey: Survey, news: AsyncStream<CableNews>.Continuation) {
    self.survey = survey
    self.news = news
  }

  func items() async -> [MediaItem] {
    await MainActor.run {
      if case .ranked(let findings) = survey.stage {
        return findings.items
      }
      return []
    }
  }

  func pieces(of id: String) async throws -> [Piece] {
    let asset = try asset(id)
    let taken = asset.creationDate ?? .distantPast
    return Placement(taken: taken, id: id, zone: .current)
      .paths(for: PHAssetResource.assetResources(for: asset).map { $0.originalFilename })
      .enumerated()
      .map { Piece(index: $0.offset, path: $0.element, taken: taken) }
  }

  func pour(_ index: Int, of id: String, fetching: Bool, into sink: any Sink) async throws {
    let resources = PHAssetResource.assetResources(for: try asset(id))
    guard resources.indices.contains(index) else {
      throw MissingOriginal()
    }
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = fetching
    let flow = Flow()
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
      let request = PHAssetResourceManager.default().requestData(
        for: resources[index],
        options: options
      ) { chunk in
        guard flow.sound() else {
          return
        }
        // PhotoKit reads as fast as the disk allows; it is held here until
        // the cable has taken the piece, so a large file never piles up in memory.
        let gate = DispatchSemaphore(value: 0)
        Task {
          do {
            try await sink.take(chunk)
            flow.passed(Int64(chunk.count))
          } catch {
            flow.broke(error)
          }
          gate.signal()
        }
        gate.wait()
        if !flow.sound() {
          flow.stop()
        }
      } completionHandler: { error in
        if let broken = flow.failure().first ?? error {
          done.resume(throwing: broken)
        } else {
          done.resume()
        }
      }
      flow.started(request)
    }
    news.yield(.poured(flow.total()))
  }

  func held(_ ids: [String]) async {
    news.yield(.held(ids))
  }

  private func asset(_ id: String) throws -> PHAsset {
    let found = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
    guard found.count > 0 else {
      throw MissingOriginal()
    }
    return found.object(at: 0)
  }
}

/// One file flowing out of the photo library: how much has gone, and whether it broke.
private final class Flow: Sendable {
  private struct Facts {
    var bytes: Int64 = 0
    var failures: [any Error] = []
    var requests: [PHAssetResourceDataRequestID] = []
  }

  private let facts = OSAllocatedUnfairLock(initialState: Facts())

  func started(_ request: PHAssetResourceDataRequestID) {
    facts.withLock { $0.requests.append(request) }
  }

  func passed(_ count: Int64) {
    facts.withLock { $0.bytes += count }
  }

  func broke(_ error: any Error) {
    facts.withLock { $0.failures.append(error) }
  }

  func sound() -> Bool {
    facts.withLock { $0.failures.isEmpty }
  }

  func failure() -> [any Error] {
    facts.withLock { $0.failures }
  }

  func total() -> Int64 {
    facts.withLock { $0.bytes }
  }

  /// Tells PhotoKit to read no further.
  func stop() {
    for request in facts.withLock({ $0.requests }) {
      PHAssetResourceManager.default().cancelDataRequest(request)
    }
  }
}

/// The hatch as it listens on this device, for connections that come through the cable.
struct Hatchway {
  private let hatch: Hatch
  private let port: UInt16

  /// - Parameters:
  ///   - hatch: What answers the requests.
  ///   - port: The port to listen on.
  init(hatch: Hatch, port: UInt16) {
    self.hatch = hatch
    self.port = port
  }

  /// Starts listening; whoever holds the listener ends it by cancelling it.
  func opened() throws -> NWListener {
    let parameters = NWParameters.tcp
    // The cable's connections arrive from this device itself; nothing else is let in.
    parameters.requiredInterfaceType = .loopback
    parameters.allowLocalEndpointReuse = true
    guard let port = NWEndpoint.Port(rawValue: port) else {
      throw URLError(.badURL)
    }
    let listener = try NWListener(using: parameters, on: port)
    let hatch = hatch
    listener.newConnectionHandler = { connection in
      connection.start(queue: .global(qos: .userInitiated))
      Hatchway.read(from: connection, after: Data(), for: hatch)
    }
    listener.start(queue: .global(qos: .userInitiated))
    return listener
  }

  /// Gathers a request's head, has it answered, and ends the connection.
  private static func read(from connection: NWConnection, after gathered: Data, for hatch: Hatch) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, ended, error in
      let head = gathered + (data ?? Data())
      if head.range(of: Data("\r\n\r\n".utf8)) != nil {
        Task {
          await hatch.serve(head, through: Line(connection: connection))
          connection.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
              connection.cancel()
            }
          )
        }
      } else if ended || error != nil || head.count > 65536 {
        connection.cancel()
      } else {
        read(from: connection, after: head, for: hatch)
      }
    }
  }
}

/// A connection as something bytes are sent into, one piece after another.
private struct Line: Sink {
  let connection: NWConnection

  func take(_ chunk: Data) async throws {
    try await withCheckedThrowingContinuation { (sent: CheckedContinuation<Void, any Error>) in
      connection.send(
        content: chunk,
        completion: .contentProcessed { error in
          if let error {
            sent.resume(throwing: error)
          } else {
            sent.resume()
          }
        }
      )
    }
  }
}
