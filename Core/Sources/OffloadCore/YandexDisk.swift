import Foundation

/// Yandex Disk as a place to keep files.
///
/// An upload asks for a one-time upload link, sends the file to it, then
/// reads back the size and MD5 the Disk recorded. A file already stored
/// under the same name is replaced, so a failed attempt can simply be
/// repeated.
///
/// The Disk slows uploads through this API to about 128 KiB/s for videos,
/// archives and data files, and decides that from the file's extension at
/// the moment the link is requested. So such a file travels under a
/// disguised name and is renamed once it has arrived.
///
/// The Disk also files an upload away after it has answered, so the stored
/// file may take a moment to appear; reading it back is retried for a while.
///
/// Besides uploading in one go, it takes a file in separate steps, for
/// uploads that the system carries out while the app is not running.
public struct YandexDisk: Cloud, Depot {
  private let api: YandexApi
  private let folder: String
  private let disguise: Disguise
  private let patience: Patience

  /// - Parameters:
  ///   - api: The Disk API of the user.
  ///   - folder: Disk path the files go under, ending with a slash.
  ///   - disguise: Decides the name each file travels under.
  ///   - patience: How long to wait for the Disk to file an upload away.
  public init(api: YandexApi, folder: String, disguise: Disguise, patience: Patience) {
    self.api = api
    self.folder = folder
    self.disguise = disguise
    self.patience = patience
  }

  /// Stores into the application's own folder, disguising what the Disk
  /// would slow down and waiting up to two minutes for a file to appear.
  public init(api: YandexApi) {
    self.init(
      api: api,
      folder: "app:/",
      disguise: Disguise(),
      patience: Patience(tries: 60, pause: .seconds(2))
    )
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
    let door = try await door(for: name, bytes: 0)
    let sent = try await api.delivery(of: file, method: door.method, to: door.url)
    guard sent.status == 201 || sent.status == 202 else {
      throw CloudRefusal(step: "Upload", response: sent)
    }
    let path = folder + name
    let travelling = folder + disguise.name(for: name)
    if travelling != path {
      _ = try await settled(travelling)
      try await rename(travelling, to: path)
    }
    let stored = try await settled(path)
    return Fingerprint(bytes: stored.size, md5: stored.md5)
  }

  /// A name may lead through folders, which are made when the Disk misses them.
  public func door(for name: String, bytes: Int64) async throws -> Request {
    let query = ["path": folder + disguise.name(for: name), "overwrite": "true"]
    var link = try await api.response(resource: "disk/resources/upload", query: query)
    if link.status == 409 || link.status == 404, name.contains("/") {
      // The Disk answers so when the folder is not there, which costs nothing to put right.
      try await folders(to: name)
      link = try await api.response(resource: "disk/resources/upload", query: query)
    }
    guard link.status == 200 else {
      throw CloudRefusal(step: "Upload link", response: link)
    }
    let slot = try JSONDecoder().decode(UploadSlot.self, from: link.body)
    guard !slot.templated, let target = URL(string: slot.href) else {
      throw UnusableUploadLink(href: slot.href)
    }
    // Upload links take no token.
    return Request(method: slot.method, url: target, headers: [:])
  }

  /// A file that arrived under a disguised name is renamed first, so asking
  /// again after an interruption picks the filing up where it stopped.
  public func shelved(_ name: String) async throws -> [Fingerprint] {
    let path = folder + name
    let travelling = folder + disguise.name(for: name)
    if travelling != path, try await !held(travelling).isEmpty {
      try await rename(travelling, to: path)
      let stored = try await settled(path)
      return [Fingerprint(bytes: stored.size, md5: stored.md5)]
    }
    return try await held(path).map { Fingerprint(bytes: $0.size, md5: $0.md5) }
  }

  /// The Disk keeps its own dates of a file, which say when it arrived and
  /// cannot be set. So the moment is kept beside them, under the name that
  /// rclone reads to give a downloaded file its date back.
  public func dated(_ name: String, at taken: Date) async throws {
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let noted = try await api.response(
      method: "PATCH",
      resource: "disk/resources",
      query: ["path": folder + name],
      json: Data(
        #"{"custom_properties":{"rclone_modified":"\#(format.string(from: taken))"}}"#.utf8
      )
    )
    guard noted.status == 200 else {
      throw CloudRefusal(step: "Date of the original", response: noted)
    }
  }

  /// Makes the folders a name leads through, outermost first.
  private func folders(to name: String) async throws {
    var path = folder
    for level in name.split(separator: "/").dropLast() {
      path += level
      let made = try await api.response(
        method: "PUT",
        resource: "disk/resources",
        query: ["path": path]
      )
      // A folder that is already there is refused with 409.
      guard made.status == 201 || made.status == 409 else {
        throw CloudRefusal(step: "Folder \(path)", response: made)
      }
      path += "/"
    }
  }

  private func rename(_ travelling: String, to path: String) async throws {
    let moved = try await api.response(
      method: "POST",
      resource: "disk/resources/move",
      query: ["from": travelling, "path": path, "overwrite": "true"]
    )
    guard moved.status == 201 || moved.status == 202 else {
      throw CloudRefusal(step: "Rename after upload", response: moved)
    }
  }

  /// What the Disk holds at the path right now; empty when nothing.
  private func held(_ path: String) async throws -> [StoredFile] {
    let response = try await api.response(
      resource: "disk/resources",
      query: ["path": path, "fields": "size,md5"]
    )
    if response.status == 404 {
      return []
    }
    guard response.status == 200 else {
      throw CloudRefusal(step: "Stored file details", response: response)
    }
    return [try JSONDecoder().decode(StoredFile.self, from: response.body)]
  }

  /// What the Disk holds at the path, waiting while it is not there yet.
  private func settled(_ path: String) async throws -> StoredFile {
    var response = Response(status: 404, body: Data())
    for attempt in 0..<patience.tries {
      if attempt > 0 {
        try await Task.sleep(for: patience.pause)
      }
      response = try await api.response(
        resource: "disk/resources",
        query: ["path": path, "fields": "size,md5"]
      )
      if response.status == 200 {
        return try JSONDecoder().decode(StoredFile.self, from: response.body)
      }
      if response.status != 404 {
        break
      }
    }
    throw CloudRefusal(step: "Stored file details", response: response)
  }
}

/// How persistently to ask for something that takes the Disk a while.
public struct Patience: Sendable {
  let tries: Int
  let pause: Duration

  /// - Parameters:
  ///   - tries: How many times to ask at most.
  ///   - pause: How long to wait between two tries.
  public init(tries: Int, pause: Duration) {
    self.tries = tries
    self.pause = pause
  }
}

/// The Disk issued an upload link this client cannot follow.
public struct UnusableUploadLink: LocalizedError, CustomStringConvertible, Verdict {
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
