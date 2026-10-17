import Foundation
import OffloadCore

/// Google's token endpoint and Drive, kept in memory and answering as the real ones do.
final class FakeGoogle: @unchecked Sendable {
  /// One file or folder of the Drive.
  struct Entry {
    var name: String
    var parent: String
    var folder: Bool
    var data: Data
    var modified: String
  }

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var sessions: [String: (target: String, name: String, parent: String)] = [:]
  private var issued = 0
  private var valid = ""
  private var heard: [Request] = []
  private let pageSize: Int

  /// - Parameter pageSize: How many files a search answers with at most per page.
  init(pageSize: Int = 1000) {
    self.pageSize = pageSize
  }

  /// The wire through which the fake is reached.
  func wire() -> FakeGoogleWire {
    FakeGoogleWire(google: self)
  }

  /// Makes the access token handed out last stop working, as if it had expired early.
  func revoke() {
    lock.withLock { valid = "revoked" }
  }

  /// How many access tokens the endpoint handed out.
  func tokens() -> Int {
    lock.withLock { issued }
  }

  /// Every request the fake was sent, in order.
  func requests() -> [Request] {
    lock.withLock { heard }
  }

  /// The paths of everything below the top folder named, folders ending with a slash.
  func tree(under top: String = "Offload") -> [String] {
    lock.withLock {
      guard let root = entries.first(where: { $0.value.name == top && $0.value.parent == "root" })
      else {
        return []
      }
      var paths: [String] = []
      func walk(_ id: String, _ prefix: String) {
        for (child, entry) in entries where entry.parent == id {
          let path = prefix + entry.name
          paths.append(entry.folder ? path + "/" : path)
          if entry.folder {
            walk(child, path + "/")
          }
        }
      }
      walk(root.key, "")
      return paths.sorted()
    }
  }

  /// The entry at the path below the top folder.
  func entry(_ path: String) -> [Entry] {
    lock.withLock {
      var parent =
        entries.first { $0.value.name == "Offload" && $0.value.parent == "root" }?.key ?? ""
      var found: [Entry] = []
      for level in path.split(separator: "/").map(String.init) {
        guard
          let next = entries.first(where: { $0.value.name == level && $0.value.parent == parent })
        else {
          return []
        }
        parent = next.key
        found = [next.value]
      }
      return found
    }
  }

  /// Puts a file into the Drive, as if someone had uploaded it before.
  func put(_ path: String, _ data: Data, modified: String = "2024-05-06T07:08:09.000Z") {
    let levels = path.split(separator: "/").map(String.init)
    lock.withLock {
      var parent = "root"
      for (depth, level) in (["Offload"] + levels).enumerated() {
        let last = depth == levels.count
        if !last,
          let id = entries.first(where: { $0.value.name == level && $0.value.parent == parent })?
            .key
        {
          parent = id
          continue
        }
        let id = "id\(entries.count + 1)"
        entries[id] = Entry(
          name: level,
          parent: parent,
          folder: !last,
          data: last ? data : Data(),
          modified: modified
        )
        parent = id
      }
    }
  }

  func answer(_ request: Request, file: Data) -> Response {
    lock.withLock {
      heard.append(request)
      let parts = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
      let query = (parts.queryItems ?? []).reduce(into: [String: String]()) {
        $0[$1.name] = $1.value ?? ""
      }
      let route = "\(request.method) \(request.url.host ?? "")\(request.url.path)"
      if route == "POST oauth2.googleapis.com/token" {
        return token(String(decoding: request.body, as: UTF8.self))
      }
      if let upload = query["upload_id"] {
        return delivered(upload, file)
      }
      if request.url.host == "lh3.googleusercontent.com" {
        return Response(status: 200, body: Data("picture \(request.url.lastPathComponent)".utf8))
      }
      guard request.headers["Authorization"] == "Bearer \(valid)", !valid.isEmpty else {
        return Response(status: 401, body: Data(#"{"error":{"code":401}}"#.utf8))
      }
      let id = request.url.lastPathComponent
      switch route {
      case "GET www.googleapis.com/drive/v3/files":
        return search(query["q"] ?? "", page: Int(query["pageToken"] ?? "") ?? 0)
      case "POST www.googleapis.com/drive/v3/files":
        let asked = json(request.body)
        let made = "id\(entries.count + 1)"
        entries[made] = Entry(
          name: asked["name"] as? String ?? "",
          parent: (asked["parents"] as? [String])?.first ?? "",
          folder: asked["mimeType"] as? String == "application/vnd.google-apps.folder",
          data: Data(),
          modified: "2026-01-01T00:00:00.000Z"
        )
        return Response(status: 200, body: Data(#"{"id":"\#(made)"}"#.utf8))
      case "POST www.googleapis.com/upload/drive/v3/files":
        let asked = json(request.body)
        return session(
          target: "",
          name: asked["name"] as? String ?? "",
          parent: (asked["parents"] as? [String])?.first ?? ""
        )
      case "PATCH www.googleapis.com/upload/drive/v3/files/\(id)":
        guard entries[id] != nil else {
          return Response(status: 404, body: Data())
        }
        return session(target: id, name: "", parent: "")
      case "PATCH www.googleapis.com/drive/v3/files/\(id)":
        guard entries[id] != nil else {
          return Response(status: 404, body: Data())
        }
        entries[id]?.modified = json(request.body)["modifiedTime"] as? String ?? ""
        return Response(status: 200, body: Data(#"{"id":"\#(id)"}"#.utf8))
      case "GET www.googleapis.com/drive/v3/files/\(id)" where query["alt"] == "media":
        guard let entry = entries[id] else {
          return Response(status: 404, body: Data())
        }
        return Response(status: 200, body: entry.data)
      default:
        return Response(status: 400, body: Data("no route \(route)".utf8))
      }
    }
  }

  private func token(_ form: String) -> Response {
    issued += 1
    valid = "access\(issued)"
    let refresh =
      form.contains("grant_type=authorization_code") ? #","refresh_token":"lasting""# : ""
    return Response(
      status: 200,
      body: Data(#"{"access_token":"\#(valid)","expires_in":3600\#(refresh)}"#.utf8)
    )
  }

  private func session(target: String, name: String, parent: String) -> Response {
    let id = "\(sessions.count + 1)"
    sessions[id] = (target, name, parent)
    return Response(
      status: 200,
      body: Data(),
      headers: [
        "location":
          "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&upload_id=\(id)"
      ]
    )
  }

  private func delivered(_ upload: String, _ data: Data) -> Response {
    guard let session = sessions[upload] else {
      return Response(status: 404, body: Data())
    }
    if !session.target.isEmpty {
      entries[session.target]?.data = data
      return Response(status: 200, body: Data(#"{"id":"\#(session.target)"}"#.utf8))
    }
    let id = "id\(entries.count + 1)"
    entries[id] = Entry(
      name: session.name,
      parent: session.parent,
      folder: false,
      data: data,
      modified: "2026-01-01T00:00:00.000Z"
    )
    return Response(status: 201, body: Data(#"{"id":"\#(id)"}"#.utf8))
  }

  /// Answers the few kinds of search the app makes: by name, by parent, by kind.
  private func search(_ q: String, page: Int) -> Response {
    let name = quoted(q, after: "name = ")
    let parent = quoted(q, before: " in parents")
    let folders = q.contains("mimeType = 'application/vnd.google-apps.folder'")
    let files = q.contains("mimeType != 'application/vnd.google-apps.folder'")
    let found = entries.filter { _, entry in
      (name.isEmpty || entry.name == name) && entry.parent == parent
        && (!folders || entry.folder) && (!files || !entry.folder)
    }.sorted { $0.value.name < $1.value.name }
    let shown = found.dropFirst(page * pageSize).prefix(pageSize)
    let items = shown.map { id, entry in
      var item: [String: Any] = [
        "id": id,
        "name": entry.name,
        "mimeType": entry.folder ? "application/vnd.google-apps.folder" : "image/jpeg",
        "modifiedTime": entry.modified,
      ]
      if !entry.folder {
        item["size"] = "\(entry.data.count)"
        item["md5Checksum"] = Md5Of(entry.data).value()
        item["thumbnailLink"] = "https://lh3.googleusercontent.com/\(id)=s220"
      }
      return item
    }
    var answer: [String: Any] = ["files": items]
    if found.count > (page + 1) * pageSize {
      answer["nextPageToken"] = "\(page + 1)"
    }
    return Response(status: 200, body: try! JSONSerialization.data(withJSONObject: answer))
  }

  /// The text in single quotes after or before a phrase, with Drive's escapes undone.
  private func quoted(_ q: String, after phrase: String = "", before end: String = "") -> String {
    let pattern =
      phrase.isEmpty
      ? #"'((?:\\.|[^'\\])*)'"# + NSRegularExpression.escapedPattern(for: end)
      : NSRegularExpression.escapedPattern(for: phrase) + #"'((?:\\.|[^'\\])*)'"#
    let regex = try! NSRegularExpression(pattern: pattern)
    guard
      let match = regex.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
      let range = Range(match.range(at: 1), in: q)
    else {
      return ""
    }
    return String(q[range]).replacingOccurrences(of: "\\'", with: "'")
      .replacingOccurrences(of: "\\\\", with: "\\")
  }

  private func json(_ body: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
  }
}

/// The network as the fake Google sees it.
struct FakeGoogleWire: Wire {
  let google: FakeGoogle

  func response(to request: Request) async throws -> Response {
    google.answer(request, file: Data())
  }

  func response(to request: Request, sending file: URL) async throws -> Response {
    google.answer(request, file: try Data(contentsOf: file))
  }

  func response(to request: Request, saving file: URL) async throws -> Response {
    let answer = google.answer(request, file: Data())
    try answer.body.write(to: file)
    return Response(status: answer.status, body: Data())
  }
}

/// A kept refresh token that a test may change.
final class KeptRefresh: Secret, @unchecked Sendable {
  private let lock = NSLock()
  private var text: String

  init(_ text: String) {
    self.text = text
  }

  func value() throws -> String {
    lock.withLock { text }
  }

  func change(to text: String) {
    lock.withLock { self.text = text }
  }
}

/// A clock a test moves on by hand.
final class HandClock: @unchecked Sendable {
  private let lock = NSLock()
  private var moment = Date(timeIntervalSince1970: 1_800_000_000)

  func now() -> Date {
    lock.withLock { moment }
  }

  func pass(_ seconds: TimeInterval) {
    lock.withLock { moment = moment.addingTimeInterval(seconds) }
  }
}

/// The MD5 of some bytes in hexadecimal, as Drive reports it.
struct Md5Of {
  private let data: Data

  init(_ data: Data) {
    self.data = data
  }

  func value() -> String {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("offload-md5-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: file)
    }
    try! data.write(to: file)
    return "\(try! FingerprintOf(file).value())".components(separatedBy: "md5 ").last ?? ""
  }
}
