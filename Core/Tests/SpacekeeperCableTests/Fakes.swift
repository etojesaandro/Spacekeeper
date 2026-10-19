import Foundation
import SpacekeeperCore

@testable import SpacekeeperCable

/// A channel that answers with bytes arranged beforehand and keeps what it was sent.
final class ScriptedChannel: Channel, @unchecked Sendable {
  private let lock = NSLock()
  private var answer: Data
  private var heard = Data()
  private var closed = false
  private let chunk: Int

  /// - Parameters:
  ///   - answer: Everything the other end says.
  ///   - chunk: At most how many bytes each receive hands out.
  init(answer: Data, chunk: Int = 7) {
    self.answer = answer
    self.chunk = chunk
  }

  func send(_ bytes: Data) throws {
    lock.withLock { heard.append(bytes) }
  }

  func received(upTo count: Int) throws -> Data {
    lock.withLock {
      let part = answer.prefix(min(count, chunk))
      answer.removeFirst(part.count)
      return Data(part)
    }
  }

  func close() {
    lock.withLock { closed = true }
  }

  func sent() -> Data {
    lock.withLock { heard }
  }

  func shut() -> Bool {
    lock.withLock { closed }
  }
}

/// A doorway that hands out the channels it was given, one per opening.
final class ArrangedDoorway: Doorway, @unchecked Sendable {
  private let lock = NSLock()
  private var channels: [any Channel]

  init(_ channels: [any Channel]) {
    self.channels = channels
  }

  func opened() throws -> any Channel {
    try lock.withLock {
      guard !channels.isEmpty else {
        throw SocketFailure(what: "reach the fake", fault: Fault(number: 111))
      }
      return channels.removeFirst()
    }
  }
}

/// A doorway behind which a phone's hatch waits, reached as usbmuxd would carry it.
struct HatchDoorway: Doorway {
  private let hatch: Hatch

  init(_ hatch: Hatch) {
    self.hatch = hatch
  }

  func opened() throws -> any Channel {
    MuxedHatch(hatch)
  }
}

/// One channel to usbmuxd that is asked to connect to the hatch and then carries one request.
final class MuxedHatch: Channel, @unchecked Sendable {
  private let hatch: Hatch
  private let lock = NSLock()
  private var connected = false
  private var served = false
  private var asked = Data()
  private var pending = Data()

  init(_ hatch: Hatch) {
    self.hatch = hatch
  }

  func send(_ bytes: Data) throws {
    try lock.withLock {
      if connected {
        asked.append(bytes)
      } else {
        connected = true
        pending.append(try MuxMessage(fields: ["MessageType": "Result", "Number": 0]).bytes())
      }
    }
  }

  func received(upTo count: Int) throws -> Data {
    let serve = lock.withLock {
      pending.isEmpty && connected && !served && asked.range(of: Data("\r\n\r\n".utf8)) != nil
    }
    if serve {
      let head = lock.withLock { asked }
      let pile = Pile()
      let done = DispatchSemaphore(value: 0)
      let hatch = hatch
      Task {
        await hatch.serve(head, through: pile)
        done.signal()
      }
      done.wait()
      let answer = pile.all()
      lock.withLock {
        served = true
        pending.append(answer)
      }
    }
    return lock.withLock {
      let part = pending.prefix(count)
      pending.removeFirst(part.count)
      return Data(part)
    }
  }

  func close() {}
}

/// A sink that piles up what it is given.
final class Pile: Sink, @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  func take(_ chunk: Data) async throws {
    lock.withLock { data.append(chunk) }
  }

  func all() -> Data {
    lock.withLock { data }
  }
}

/// A library of a few items, each made of the files given.
struct LittleStock: Stock {
  private let listed: [MediaItem]
  private let contents: [String: [Data]]

  init(_ listed: [MediaItem], contents: [String: [Data]]) {
    self.listed = listed
    self.contents = contents
  }

  func items() async -> [MediaItem] {
    listed
  }

  func pieces(of id: String) async throws -> [Piece] {
    (contents[id] ?? []).indices.map { index in
      Piece(
        index: index,
        path: "2024/05/\(id)_\(index).JPG",
        taken: Date(timeIntervalSince1970: 1_715_000_000)
      )
    }
  }

  func pour(_ index: Int, of id: String, fetching: Bool, into sink: any Sink) async throws {
    try await sink.take(contents[id]![index])
  }

  func held(_ ids: [String]) async {}
}

/// The answer usbmuxd gives to a request, framed as it sends it.
struct MuxReply {
  private let fields: [String: Any]

  init(_ fields: [String: Any]) {
    self.fields = fields
  }

  func bytes() throws -> Data {
    try MuxMessage(fields: fields).bytes()
  }
}

/// The property list carried by a message as it went over a channel.
struct SentMessage {
  private let bytes: Data

  init(_ bytes: Data) {
    self.bytes = bytes
  }

  func fields() -> [String: Any] {
    (try? PropertyListSerialization.propertyList(from: bytes.dropFirst(16), format: nil))
      as? [String: Any] ?? [:]
  }

  func header() -> [UInt32] {
    stride(from: 0, to: 16, by: 4).map { start in
      bytes.dropFirst(start).prefix(4).enumerated().reduce(UInt32(0)) { sum, byte in
        sum | UInt32(byte.element) << (8 * UInt32(byte.offset))
      }
    }
  }
}
