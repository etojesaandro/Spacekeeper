import Crypto
import Foundation

/// What a phone can hand out of its photo library.
public protocol Stock: Sendable {
  /// Every item of the photo library.
  func items() async -> [MediaItem]

  /// The files the item with the identifier is stored as.
  func pieces(of id: String) async throws -> [Piece]

  /// Pours one file of an item into a sink, piece by piece.
  ///
  /// - Parameter fetching: Whether a file that is only in iCloud is fetched for it.
  func pour(_ index: Int, of id: String, fetching: Bool, into sink: any Sink) async throws

  /// A computer says it safely holds the items with these identifiers.
  func held(_ ids: [String]) async
}

/// Something bytes are sent into, which takes them no faster than it can.
public protocol Sink: Sendable {
  func take(_ chunk: Data) async throws
}

/// The opening through which a computer reaches the phone's photo library.
///
/// It speaks just enough HTTP to be asked with ordinary tools: one request
/// per connection, answered and closed. Every request must carry the code
/// the phone shows on its screen, so that nothing else on the phone can
/// read the library through it.
///
/// A file is sent followed by the MD5 of what was sent, as 32 letters. The
/// length of a file is not always known beforehand, and a stream cut short
/// would otherwise pass for a whole one.
public struct Hatch: Sendable {
  private let stock: any Stock
  private let code: String

  /// - Parameters:
  ///   - stock: What is handed out.
  ///   - code: What a request must carry to be answered.
  public init(stock: any Stock, code: String) {
    self.stock = stock
    self.code = code
  }

  /// Answers one request, given its head, into the sink.
  public func serve(_ head: Data, through sink: any Sink) async {
    let asked = Asked(head)
    do {
      guard asked.header("x-offload-code") == code else {
        return try await sink.take(reply(403, "The code is wrong or missing"))
      }
      switch "\(asked.method) \(asked.path)" {
      case "GET /items":
        try await sink.take(reply(200, try JSONEncoder().encode(await stock.items())))
      case "GET /pieces":
        let pieces = try await stock.pieces(of: asked.value("id"))
        try await sink.take(reply(200, try JSONEncoder().encode(pieces)))
      case "GET /content":
        let stream = Stream(sink)
        do {
          try await stock.pour(
            Int(asked.value("index")) ?? 0,
            of: asked.value("id"),
            fetching: asked.value("icloud") == "1",
            into: stream
          )
          try await stream.end()
        } catch {
          // Once the file has begun there is no taking it back: it simply stops short.
          if await !stream.begun() {
            try await sink.take(reply(500, error.localizedDescription))
          }
        }
      case "POST /held":
        await stock.held(asked.values("id"))
        try await sink.take(reply(200, "Noted"))
      default:
        try await sink.take(reply(404, "No such thing here"))
      }
    } catch {
      try? await sink.take(reply(500, error.localizedDescription))
    }
  }

  private func reply(_ status: Int, _ text: String) -> Data {
    reply(status, Data(text.utf8))
  }

  private func reply(_ status: Int, _ body: Data) -> Data {
    let lines = [
      "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Refused")",
      "Content-Length: \(body.count)",
      "Connection: close",
    ]
    return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
  }
}

/// The head of an HTTP request, read for what the hatch needs.
struct Asked {
  let method: String
  let path: String
  private let query: [URLQueryItem]
  private let headers: [String: String]

  init(_ head: Data) {
    let lines = String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n")
    let first = (lines.first ?? "").split(separator: " ").map(String.init)
    let target = URLComponents(string: first.count > 1 ? first[1] : "")
    method = first.first ?? ""
    path = target?.path ?? ""
    query = target?.queryItems ?? []
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      let sides = line.split(separator: ":", maxSplits: 1).map(String.init)
      if sides.count == 2 {
        headers[sides[0].lowercased()] = sides[1].trimmingCharacters(in: .whitespaces)
      }
    }
    self.headers = headers
  }

  /// The header with the lowercase name; empty when it was not sent.
  func header(_ name: String) -> String {
    headers[name] ?? ""
  }

  /// The first value of a query parameter; empty when it was not sent.
  func value(_ name: String) -> String {
    values(name).first ?? ""
  }

  /// Every value of a query parameter.
  func values(_ name: String) -> [String] {
    query.filter { $0.name == name }.map { $0.value ?? "" }
  }
}

/// A file on its way out: it opens the answer with the first bytes and
/// counts the MD5 of everything it passes on.
private actor Stream: Sink {
  private let sink: any Sink
  private var hash = Insecure.MD5()
  private var started = false

  init(_ sink: any Sink) {
    self.sink = sink
  }

  func take(_ chunk: Data) async throws {
    try await open()
    hash.update(data: chunk)
    try await sink.take(chunk)
  }

  /// Closes the file with the MD5 of what went before.
  func end() async throws {
    try await open()
    try await sink.take(
      Data(hash.finalize().map { String(format: "%02x", $0) }.joined().utf8)
    )
  }

  func begun() -> Bool {
    started
  }

  private func open() async throws {
    if !started {
      started = true
      let lines = ["HTTP/1.1 200 OK", "Content-Type: application/octet-stream", "Connection: close"]
      try await sink.take(Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8))
    }
  }
}
