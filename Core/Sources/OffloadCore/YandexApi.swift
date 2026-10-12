import Foundation

/// Yandex Disk's REST API on behalf of one user.
public struct YandexApi: Sendable {
  private let token: String
  private let wire: any Wire
  private let root: URL

  /// - Parameters:
  ///   - token: OAuth token of the user.
  ///   - wire: Network to talk through.
  ///   - root: Root of the Disk REST API, ending with a slash.
  public init(token: String, wire: any Wire, root: URL) {
    self.token = token
    self.wire = wire
    self.root = root
  }

  /// Talks to the public API.
  public init(token: String, wire: any Wire) {
    self.init(token: token, wire: wire, root: URL(string: "https://cloud-api.yandex.net/v1/")!)
  }

  /// Asks the API a question and returns its answer whatever the status.
  func response(resource: String, query: [String: String]) async throws -> Response {
    try await response(method: "GET", resource: resource, query: query)
  }

  /// Sends the API a request without a body and returns its answer whatever the status.
  func response(
    method: String,
    resource: String,
    query: [String: String]
  ) async throws -> Response {
    try await wire.response(
      to: Request(
        method: method,
        url: address(resource: resource, query: query),
        headers: ["Authorization": "OAuth \(token)", "Accept": "application/json"]
      )
    )
  }

  /// Asks the API a question that must succeed and decodes the answer.
  func answer<Body: Decodable>(
    _ body: Body.Type,
    step: String,
    resource: String,
    query: [String: String]
  ) async throws -> Body {
    let response = try await response(resource: resource, query: query)
    guard response.status == 200 else {
      throw CloudRefusal(step: step, response: response)
    }
    return try JSONDecoder().decode(body, from: response.body)
  }

  /// Sends a file to an address the API handed out; such addresses take no token.
  func delivery(of file: URL, method: String, to target: URL) async throws -> Response {
    try await wire.response(
      to: Request(method: method, url: target, headers: [:]),
      sending: file
    )
  }

  private func address(resource: String, query: [String: String]) -> URL {
    var parts = URLComponents(
      url: root.appendingPathComponent(resource),
      resolvingAgainstBaseURL: false
    )!
    parts.queryItems = query.sorted { $0.key < $1.key }.map {
      URLQueryItem(name: $0.key, value: $0.value)
    }
    // URLComponents leaves "+" as is, and servers read a bare "+" as a space.
    parts.percentEncodedQuery = parts.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    return parts.url!
  }
}
