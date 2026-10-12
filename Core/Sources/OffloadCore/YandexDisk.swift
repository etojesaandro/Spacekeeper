import Foundation

/// Yandex Disk, reached through its REST API.
///
/// An upload takes three calls: ask for a one-time upload link, send the
/// file to it, then read back the size and MD5 the Disk recorded. A file
/// already stored under the same name is replaced, so a failed attempt can
/// simply be repeated.
public struct YandexDisk: Cloud {
  private let token: String
  private let wire: any Wire
  private let folder: String
  private let api: URL

  /// - Parameters:
  ///   - token: OAuth token of the user.
  ///   - wire: Network to talk through.
  ///   - folder: Disk path the files go under, ending with a slash.
  ///   - api: Root of the Disk REST API.
  public init(token: String, wire: any Wire, folder: String, api: URL) {
    self.token = token
    self.wire = wire
    self.folder = folder
    self.api = api
  }

  /// Talks to the public API and stores into the application's own folder.
  public init(token: String, wire: any Wire) {
    self.init(
      token: token,
      wire: wire,
      folder: "app:/",
      api: URL(string: "https://cloud-api.yandex.net/v1/disk/")!
    )
  }

  /// Talks over the real network.
  public init(token: String) {
    self.init(token: token, wire: URLSessionWire())
  }

  public func kept(_ file: URL, as name: String) async throws -> Fingerprint {
    let path = folder + name
    let slot = try await answer(
      UploadSlot.self,
      step: "Upload link",
      resource: "resources/upload",
      query: ["path": path, "overwrite": "true"]
    )
    guard !slot.templated, let target = URL(string: slot.href) else {
      throw UnusableUploadLink(href: slot.href)
    }
    let sent = try await wire.response(
      to: Request(method: slot.method, url: target, headers: [:]),
      sending: file
    )
    guard sent.status == 201 || sent.status == 202 else {
      throw CloudRefusal(step: "Upload", response: sent)
    }
    let stored = try await answer(
      StoredFile.self,
      step: "Stored file details",
      resource: "resources",
      query: ["path": path, "fields": "size,md5"]
    )
    return Fingerprint(bytes: stored.size, md5: stored.md5)
  }

  private func answer<Body: Decodable>(
    _ body: Body.Type,
    step: String,
    resource: String,
    query: [String: String]
  ) async throws -> Body {
    let response = try await wire.response(
      to: Request(
        method: "GET",
        url: address(resource: resource, query: query),
        headers: ["Authorization": "OAuth \(token)", "Accept": "application/json"]
      )
    )
    guard response.status == 200 else {
      throw CloudRefusal(step: step, response: response)
    }
    return try JSONDecoder().decode(body, from: response.body)
  }

  private func address(resource: String, query: [String: String]) -> URL {
    var parts = URLComponents(
      url: api.appendingPathComponent(resource),
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

/// The Disk issued an upload link this client cannot follow.
public struct UnusableUploadLink: LocalizedError, CustomStringConvertible {
  private let href: String

  init(href: String) {
    self.href = href
  }

  public var description: String {
    "Yandex Disk issued an upload link that cannot be used as is: \(href)"
  }

  public var errorDescription: String? {
    description
  }
}

// Decodable requires readable stored properties; these two only mirror the API's JSON.
private struct UploadSlot: Decodable {
  let href: String
  let method: String
  let templated: Bool
}

private struct StoredFile: Decodable {
  let size: Int64
  let md5: String
}
