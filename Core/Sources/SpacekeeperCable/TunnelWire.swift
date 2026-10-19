import Foundation
import SpacekeeperCore

/// A port of a phone reached with HTTP through the cable.
///
/// Every request goes over a tunnel of its own, which the phone closes once
/// it has answered. The work is done on a thread of its own, because the
/// sockets wait while bytes travel.
public struct TunnelWire: Wire {
  private let muxd: Muxd
  private let phone: Phone
  private let port: UInt16

  /// - Parameters:
  ///   - muxd: The service that carries connections over the cable.
  ///   - phone: The phone to talk to.
  ///   - port: Its port that answers HTTP.
  public init(muxd: Muxd, phone: Phone, port: UInt16) {
    self.muxd = muxd
    self.phone = phone
    self.port = port
  }

  public func response(to request: Request) async throws -> Response {
    try await apart { [self] in
      let exchange = try opened(request, length: request.body.count)
      defer {
        exchange.close()
      }
      try exchange.send(request.body)
      let (status, body) = try answered(over: exchange)
      var all = Data()
      try body.each { all.append($0) }
      return Response(status: status, body: all)
    }
  }

  public func response(to request: Request, sending file: URL) async throws -> Response {
    try await apart { [self] in
      let facts = try FileManager.default.attributesOfItem(atPath: file.path)
      let length = (facts[.size] as? NSNumber)?.intValue ?? 0
      let exchange = try opened(request, length: length)
      defer {
        exchange.close()
      }
      let source = try FileHandle(forReadingFrom: file)
      defer {
        try? source.close()
      }
      while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
        try exchange.send(chunk)
      }
      let (status, body) = try answered(over: exchange)
      var all = Data()
      try body.each { all.append($0) }
      return Response(status: status, body: all)
    }
  }

  public func response(to request: Request, saving file: URL) async throws -> Response {
    try await apart { [self] in
      let exchange = try opened(request, length: request.body.count)
      defer {
        exchange.close()
      }
      try exchange.send(request.body)
      let (status, body) = try answered(over: exchange)
      try? FileManager.default.removeItem(at: file)
      guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
      }
      let target = try FileHandle(forWritingTo: file)
      defer {
        try? target.close()
      }
      try body.each { try target.write(contentsOf: $0) }
      return Response(status: status, body: Data())
    }
  }

  /// A tunnel that has been sent the head of the request.
  private func opened(_ request: Request, length: Int) throws -> any Channel {
    let channel = try muxd.tunnel(to: phone, port: port)
    do {
      let parts = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
      let path = parts?.percentEncodedPath ?? "/"
      let query = parts?.percentEncodedQuery.map { "?\($0)" } ?? ""
      var lines = [
        "\(request.method) \(path.isEmpty ? "/" : path)\(query) HTTP/1.1",
        "Host: \(request.url.host ?? "localhost")",
      ]
      lines += request.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
      lines += ["Content-Length: \(length)", "Connection: close", "", ""]
      try channel.send(Data(lines.joined(separator: "\r\n").utf8))
      return channel
    } catch {
      channel.close()
      throw error
    }
  }

  /// The status of the answer and what follows its head.
  private func answered(over channel: any Channel) throws -> (Int, AnswerBody) {
    var received = Data()
    let end = Data("\r\n\r\n".utf8)
    while received.range(of: end) == nil {
      guard received.count < 65_536 else {
        throw GarbledAnswer()
      }
      let more = try channel.received(upTo: 65_536)
      guard !more.isEmpty else {
        throw ChannelEnded(what: "the head of an answer")
      }
      received.append(more)
    }
    let split = received.range(of: end)!
    let head = String(decoding: received[..<split.lowerBound], as: UTF8.self)
      .components(separatedBy: "\r\n")
    let words = head.first?.split(separator: " ") ?? []
    guard words.count >= 2, words[0].hasPrefix("HTTP/"), let status = Int(words[1]) else {
      throw GarbledAnswer()
    }
    let length = head.dropFirst().compactMap { line -> Int? in
      let pair = line.split(separator: ":", maxSplits: 1)
      guard pair.count == 2, pair[0].lowercased() == "content-length" else {
        return nil
      }
      return Int(pair[1].trimmingCharacters(in: .whitespaces))
    }.first
    return (
      status,
      AnswerBody(channel: channel, start: Data(received[split.upperBound...]), length: length)
    )
  }

  /// Runs blocking work off the threads that async code shares.
  private func apart<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(with: Result { try work() })
      }
    }
  }
}

/// The body of an answer, read off the channel chunk by chunk.
///
/// It ends where the answer's length says, or where the phone closes the
/// channel when the answer named no length.
struct AnswerBody {
  private let channel: any Channel
  private let start: Data
  private let length: Int?

  init(channel: any Channel, start: Data, length: Int?) {
    self.channel = channel
    self.start = start
    self.length = length
  }

  /// Hands every chunk of the body, in order, to the closure.
  func each(_ take: (Data) throws -> Void) throws {
    let limit = length ?? Int.max
    var got = min(start.count, limit)
    if got > 0 {
      try take(start.prefix(got))
    }
    while got < limit {
      let more = try channel.received(upTo: min(1 << 20, limit - got))
      guard !more.isEmpty else {
        guard length == nil else {
          throw ChannelEnded(what: "an answer")
        }
        return
      }
      try take(more)
      got += more.count
    }
  }
}

/// The phone answered with something that is not HTTP.
public struct GarbledAnswer: LocalizedError, CustomStringConvertible {
  public var description: String {
    "The phone answered with something that is not HTTP"
  }

  public var errorDescription: String? {
    description
  }
}
