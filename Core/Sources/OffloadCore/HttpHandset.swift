import Foundation

/// The phone reached through its hatch, over HTTP.
public struct HttpHandset: Handset {
  private let wire: any Wire
  private let root: URL
  private let code: String
  private let reach: Reach

  /// - Parameters:
  ///   - wire: Network to talk through.
  ///   - root: Address of the hatch, ending with a slash.
  ///   - code: The code the phone shows on its screen.
  ///   - reach: Whether the phone is asked to fetch from iCloud what it lacks.
  public init(wire: any Wire, root: URL, code: String, reach: Reach) {
    self.wire = wire
    self.root = root
    self.code = code
    self.reach = reach
  }

  public func items() async throws -> [MediaItem] {
    try JSONDecoder().decode([MediaItem].self, from: try await asked("GET", "items", []).body)
  }

  public func pieces(of item: MediaItem) async throws -> [Piece] {
    try JSONDecoder().decode(
      [Piece].self,
      from: try await asked("GET", "pieces", [URLQueryItem(name: "id", value: item.id)]).body
    )
  }

  public func fetched(
    _ piece: Piece,
    of item: MediaItem,
    into file: URL
  ) async throws -> Fingerprint {
    let request = request(
      "GET",
      "content",
      [
        URLQueryItem(name: "id", value: item.id),
        URLQueryItem(name: "index", value: "\(piece.index)"),
        URLQueryItem(name: "icloud", value: reach == .everything ? "1" : "0"),
      ]
    )
    let answer = try await wire.response(to: request, saving: file)
    guard answer.status == 200 else {
      throw HatchRefusal(
        what: piece.path,
        status: answer.status,
        words: (try? String(contentsOf: file, encoding: .utf8)) ?? ""
      )
    }
    // The file ends with the MD5 of what the phone sent, which is cut off here.
    let handle = try FileHandle(forUpdating: file)
    defer {
      try? handle.close()
    }
    let length = try handle.seekToEnd()
    guard length >= 32 else {
      throw CutShort(what: piece.path)
    }
    try handle.seek(toOffset: length - 32)
    let md5 = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
    try handle.truncate(atOffset: length - 32)
    return Fingerprint(bytes: Int64(length) - 32, md5: md5)
  }

  public func told(holding items: [MediaItem]) async throws {
    let ids = items.map { URLQueryItem(name: "id", value: $0.id) }
    for start in stride(from: 0, to: ids.count, by: 50) {
      _ = try await asked("POST", "held", Array(ids[start..<min(start + 50, ids.count)]))
    }
  }

  private func asked(
    _ method: String,
    _ resource: String,
    _ query: [URLQueryItem]
  ) async throws -> Response {
    let answer = try await wire.response(to: request(method, resource, query))
    guard answer.status == 200 else {
      throw HatchRefusal(
        what: resource,
        status: answer.status,
        words: String(decoding: answer.body, as: UTF8.self)
      )
    }
    return answer
  }

  private func request(_ method: String, _ resource: String, _ query: [URLQueryItem]) -> Request {
    var parts = URLComponents(
      url: root.appendingPathComponent(resource),
      resolvingAgainstBaseURL: false
    )!
    parts.queryItems = query.isEmpty ? nil : query
    // URLComponents leaves "+" as is, and servers read a bare "+" as a space.
    parts.percentEncodedQuery = parts.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    return Request(method: method, url: parts.url!, headers: ["X-Offload-Code": code])
  }
}

/// The phone answered a request with something other than success.
public struct HatchRefusal: LocalizedError, CustomStringConvertible {
  private let what: String
  private let status: Int
  private let words: String

  init(what: String, status: Int, words: String) {
    self.what = what
    self.status = status
    self.words = words
  }

  public var description: String {
    "The phone refused \(what) with HTTP \(status): \(words)"
  }

  public var errorDescription: String? {
    description
  }
}

/// A file arrived too short to carry even its own MD5.
public struct CutShort: LocalizedError, CustomStringConvertible {
  private let what: String

  init(what: String) {
    self.what = what
  }

  public var description: String {
    "\(what) arrived cut short"
  }

  public var errorDescription: String? {
    description
  }
}
