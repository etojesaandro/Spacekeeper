import Foundation

/// Yandex Disk as a place to keep files.
///
/// An upload takes three calls: ask for a one-time upload link, send the
/// file to it, then read back the size and MD5 the Disk recorded. A file
/// already stored under the same name is replaced, so a failed attempt can
/// simply be repeated.
public struct YandexDisk: Cloud {
  private let api: YandexApi
  private let folder: String

  /// - Parameters:
  ///   - api: The Disk API of the user.
  ///   - folder: Disk path the files go under, ending with a slash.
  public init(api: YandexApi, folder: String) {
    self.api = api
    self.folder = folder
  }

  /// Stores into the application's own folder.
  public init(api: YandexApi) {
    self.init(api: api, folder: "app:/")
  }

  /// Talks to the public API through the given network.
  public init(token: String, wire: any Wire) {
    self.init(api: YandexApi(token: token, wire: wire))
  }

  /// Talks over the real network.
  public init(token: String) {
    self.init(token: token, wire: URLSessionWire())
  }

  public func kept(_ file: URL, as name: String) async throws -> Fingerprint {
    let path = folder + name
    let slot = try await api.answer(
      UploadSlot.self,
      step: "Upload link",
      resource: "disk/resources/upload",
      query: ["path": path, "overwrite": "true"]
    )
    guard !slot.templated, let target = URL(string: slot.href) else {
      throw UnusableUploadLink(href: slot.href)
    }
    let sent = try await api.delivery(of: file, method: slot.method, to: target)
    guard sent.status == 201 || sent.status == 202 else {
      throw CloudRefusal(step: "Upload", response: sent)
    }
    let stored = try await api.answer(
      StoredFile.self,
      step: "Stored file details",
      resource: "disk/resources",
      query: ["path": path, "fields": "size,md5"]
    )
    return Fingerprint(bytes: stored.size, md5: stored.md5)
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
