import Foundation

/// A two-way stream of bytes to someone at the other end.
public protocol Channel: Sendable {
  /// Sends all the bytes, waiting until the other end has taken them.
  func send(_ bytes: Data) throws

  /// Some of the bytes the other end has sent, at most so many; empty once it has finished.
  func received(upTo count: Int) throws -> Data

  /// Ends the stream; nothing can be sent or received afterwards.
  func close()
}

/// A place a channel can be opened to.
public protocol Doorway: Sendable {
  /// A new channel to whoever waits behind the doorway.
  func opened() throws -> any Channel
}

/// The other end closed the channel before saying all it was expected to.
public struct ChannelEnded: LocalizedError, CustomStringConvertible {
  private let what: String

  init(what: String) {
    self.what = what
  }

  public var description: String {
    "The connection ended in the middle of \(what)"
  }

  public var errorDescription: String? {
    description
  }
}

extension Channel {
  /// Exactly so many bytes, waiting for all of them to come.
  func received(exactly count: Int, what: String) throws -> Data {
    var bytes = Data()
    while bytes.count < count {
      let more = try received(upTo: count - bytes.count)
      guard !more.isEmpty else {
        throw ChannelEnded(what: what)
      }
      bytes.append(more)
    }
    return bytes
  }
}
