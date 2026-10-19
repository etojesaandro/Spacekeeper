import Foundation

/// Something kept that only its owner can read, such as a token in the keychain.
public protocol Secret: Sendable {
  /// The kept text.
  func value() throws -> String
}

/// The access token of whoever is signed in to Google, renewed when it runs out.
///
/// Only the refresh token is kept for good. The access token lasts an hour,
/// so it is bought anew when the app starts and whenever it expires or Drive
/// stops taking it. Several requests that find it stale wait for one renewal.
public actor GoogleBearer {
  private let tokens: GoogleTokens
  private let refresh: any Secret
  private let now: @Sendable () -> Date
  private var grants: [GoogleGrant] = []
  private var renewals: [Task<GoogleGrant, any Error>] = []

  /// - Parameters:
  ///   - tokens: Google's token endpoint.
  ///   - refresh: Where the refresh token is kept.
  ///   - now: The clock to tell expiry by.
  public init(tokens: GoogleTokens, refresh: any Secret, now: @escaping @Sendable () -> Date) {
    self.tokens = tokens
    self.refresh = refresh
    self.now = now
  }

  public init(tokens: GoogleTokens, refresh: any Secret) {
    self.init(tokens: tokens, refresh: refresh, now: { Date() })
  }

  /// An access token that works now.
  public func token() async throws -> String {
    let kept = try refresh.value()
    if let grant = grants.first, grant.refresh == kept, grant.expiry > now() {
      return grant.access
    }
    let renewal = renewals.first ?? Task { [tokens] in try await tokens.renewed(kept) }
    renewals = [renewal]
    defer {
      renewals = []
    }
    let grant = try await renewal.value
    grants = [grant]
    return grant.access
  }

  /// Drive refused the token, so the next request buys a new one.
  public func spoiled() {
    grants = []
  }
}

/// Google Drive's API on behalf of one user.
public struct GoogleApi: Sendable {
  private let bearer: GoogleBearer
  private let wire: any Wire

  /// - Parameters:
  ///   - bearer: The user's access token.
  ///   - wire: Network to talk through.
  public init(bearer: GoogleBearer, wire: any Wire) {
    self.bearer = bearer
    self.wire = wire
  }

  /// Asks Drive's metadata API and returns its answer whatever the status.
  func response(
    method: String,
    resource: String,
    query: [String: String]
  ) async throws -> Response {
    try await response(method: method, url: address("drive/v3/", resource, query), json: Data())
  }

  /// Sends Drive's metadata API a JSON body and returns its answer whatever the status.
  func response(
    method: String,
    resource: String,
    query: [String: String],
    json: Data
  ) async throws -> Response {
    try await response(method: method, url: address("drive/v3/", resource, query), json: json)
  }

  /// Opens a resumable upload and returns Drive's answer whatever the status.
  func upload(
    method: String,
    resource: String,
    query: [String: String],
    json: Data
  ) async throws -> Response {
    try await response(
      method: method, url: address("upload/drive/v3/", resource, query), json: json)
  }

  /// Saves what Drive's metadata API answers into a file.
  func saved(resource: String, query: [String: String], to file: URL) async throws -> Response {
    let url = address("drive/v3/", resource, query)
    let first = try await wire.response(
      to: request("GET", url, try await bearer.token(), Data()), saving: file)
    guard first.status == 401 else {
      return first
    }
    await bearer.spoiled()
    return try await wire.response(
      to: request("GET", url, try await bearer.token(), Data()), saving: file)
  }

  /// Reads a picture at an address Drive handed out; the token goes only to Google's own hosts.
  func content(at address: URL) async throws -> Response {
    let host = address.host ?? ""
    let own = ["googleusercontent.com", "googleapis.com", "google.com"].contains {
      host == $0 || host.hasSuffix(".\($0)")
    }
    guard own, address.scheme == "https" else {
      return try await wire.response(to: Request(method: "GET", url: address, headers: [:]))
    }
    return try await response(method: "GET", url: address, json: Data())
  }

  /// Sends a file to an upload address Drive handed out; such addresses take no token.
  func delivery(of file: URL, through door: Request) async throws -> Response {
    try await wire.response(to: door, sending: file)
  }

  private func response(method: String, url: URL, json: Data) async throws -> Response {
    let first = try await wire.response(to: request(method, url, try await bearer.token(), json))
    guard first.status == 401 else {
      return first
    }
    // The token may have been withdrawn or run out early; one renewal is worth a try.
    await bearer.spoiled()
    return try await wire.response(to: request(method, url, try await bearer.token(), json))
  }

  private func request(_ method: String, _ url: URL, _ token: String, _ json: Data) -> Request {
    var headers = ["Authorization": "Bearer \(token)", "Accept": "application/json"]
    if !json.isEmpty {
      headers["Content-Type"] = "application/json; charset=UTF-8"
    }
    return Request(method: method, url: url, headers: headers, body: json)
  }

  private func address(_ base: String, _ resource: String, _ query: [String: String]) -> URL {
    var parts = URLComponents(string: "https://www.googleapis.com/\(base)\(resource)")!
    parts.queryItems =
      query.isEmpty
      ? nil : query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
    // URLComponents leaves "+" as is, and servers read a bare "+" as a space.
    parts.percentEncodedQuery = parts.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    return parts.url!
  }
}
