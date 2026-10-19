import Foundation

/// Google Drive as a place to keep files.
///
/// Files go into a folder of the user's Drive, in folders by year and month
/// as on Yandex Disk. Drive tells folders and files apart by identifiers,
/// not by paths, and lets several files share a name, so a path is followed
/// level by level, and a file sent under a name that is taken replaces the
/// one there rather than lying beside it.
///
/// An upload opens a session first; its address takes no token and lasts a
/// week, so the system can carry the file while the app is not running.
/// Drive keeps the date a file was changed as it is told, so the moment the
/// original was made becomes the file's own date.
public struct GoogleDrive: Cloud, Depot, Archive {
  private let api: GoogleApi
  private let tree: DriveTree

  /// - Parameters:
  ///   - api: The Drive API of the user.
  ///   - tree: The folders of the user's Drive that the files go under.
  public init(api: GoogleApi, tree: DriveTree) {
    self.api = api
    self.tree = tree
  }

  /// Keeps the files in the folder "Spacekeeper" at the top of the user's Drive.
  public init(api: GoogleApi) {
    self.init(api: api, tree: DriveTree(api: api, top: "Spacekeeper"))
  }

  public func kept(_ file: URL, as name: String) async throws -> Fingerprint {
    let door = try await door(for: name, bytes: 0)
    let sent = try await api.delivery(of: file, through: door)
    guard sent.status == 200 || sent.status == 201 else {
      throw CloudRefusal(step: "Upload", response: sent)
    }
    guard let stored = try await shelved(name).first else {
      throw CloudRefusal(step: "Stored file details", response: sent)
    }
    return stored
  }

  public func door(for name: String, bytes: Int64) async throws -> Request {
    let place = DrivePath(name)
    let parent = try await tree.folder(place.folder(), making: true)[0]
    let taken = try await files(named: place.leaf(), in: parent, fields: "id")
    let session: Response
    if let existing = taken.first {
      session = try await api.upload(
        method: "PATCH",
        resource: "files/\(existing.id)",
        query: ["uploadType": "resumable"],
        json: Data("{}".utf8)
      )
    } else {
      session = try await api.upload(
        method: "POST",
        resource: "files",
        query: ["uploadType": "resumable"],
        json: try JSONEncoder().encode(NewFile(name: place.leaf(), parents: [parent]))
      )
    }
    guard session.status == 200, let target = URL(string: session.header("Location")),
      target.scheme == "https"
    else {
      throw CloudRefusal(step: "Upload session", response: session)
    }
    // The session address is all the authority the upload needs.
    return Request(method: "PUT", url: target, headers: [:])
  }

  public func shelved(_ name: String) async throws -> [Fingerprint] {
    let place = DrivePath(name)
    guard let parent = try await tree.folder(place.folder(), making: false).first else {
      return []
    }
    return try await files(named: place.leaf(), in: parent, fields: "id,size,md5Checksum")
      .map { Fingerprint(bytes: Int64($0.size ?? "") ?? 0, md5: $0.md5Checksum ?? "") }
  }

  public func dated(_ name: String, at taken: Date) async throws {
    let place = DrivePath(name)
    guard let parent = try await tree.folder(place.folder(), making: false).first else {
      throw MissingOnDrive(name: name)
    }
    let found = try await files(named: place.leaf(), in: parent, fields: "id")
    guard !found.isEmpty else {
      throw MissingOnDrive(name: name)
    }
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for file in found {
      let noted = try await api.response(
        method: "PATCH",
        resource: "files/\(file.id)",
        query: ["fields": "id"],
        json: Data(#"{"modifiedTime":"\#(format.string(from: taken))"}"#.utf8)
      )
      guard noted.status == 200 else {
        throw CloudRefusal(step: "Date of the original", response: noted)
      }
    }
  }

  public func shelf(_ path: String) async throws -> Shelf {
    guard let folder = try await tree.folder(path, making: false).first else {
      return Shelf(folders: [], files: [])
    }
    var folders: [String] = []
    var files: [KeptFile] = []
    for item in try await listed(
      "'\(DriveQuote(folder).value())' in parents and trashed = false",
      fields: "id,name,mimeType,size,md5Checksum,modifiedTime,thumbnailLink"
    ) {
      let below = path.isEmpty ? item.name : "\(path)/\(item.name)"
      if item.mimeType == DriveTree.folderType {
        folders.append(below)
      } else {
        let bytes = Int64(item.size ?? "") ?? 0
        files.append(
          KeptFile(
            path: below,
            bytes: bytes,
            print: Fingerprint(bytes: bytes, md5: item.md5Checksum ?? ""),
            made: made(item.modifiedTime ?? ""),
            preview: URL(string: item.thumbnailLink ?? "").map { [$0] } ?? []
          )
        )
      }
    }
    return Shelf(folders: folders, files: files)
  }

  public func thumbnail(of file: KeptFile) async throws -> Data {
    guard let address = file.preview.first else {
      throw NoPicture(name: file.name())
    }
    return try await image(at: address, of: file)
  }

  /// Drive hands out small pictures only; the size in the address is asked bigger.
  public func picture(of file: KeptFile) async throws -> Data {
    let found = try await one(file.id, fields: "id,thumbnailLink")
    let small = found.thumbnailLink ?? ""
    guard !small.isEmpty else {
      throw NoPicture(name: file.name())
    }
    let large =
      small.range(of: "=s[0-9]+$", options: .regularExpression)
      .map { small.replacingCharacters(in: $0, with: "=s1600") } ?? small
    guard let address = URL(string: large) else {
      throw NoPicture(name: file.name())
    }
    return try await image(at: address, of: file)
  }

  public func fetched(_ file: KeptFile, into place: URL) async throws {
    let found = try await one(file.id, fields: "id")
    let saved = try await api.saved(
      resource: "files/\(found.id)",
      query: ["alt": "media"],
      to: place
    )
    guard saved.status == 200 else {
      throw CloudRefusal(step: "Download", response: saved)
    }
  }

  private func image(at address: URL, of file: KeptFile) async throws -> Data {
    let shown = try await api.content(at: address)
    guard shown.status == 200 else {
      throw CloudRefusal(step: "Picture of \(file.name())", response: shown)
    }
    return shown.body
  }

  /// The file kept at the path; the first of them when several share it.
  private func one(_ path: String, fields: String) async throws -> DriveFile {
    let place = DrivePath(path)
    guard
      let parent = try await tree.folder(place.folder(), making: false).first,
      let found = try await files(named: place.leaf(), in: parent, fields: fields).first
    else {
      throw MissingOnDrive(name: path)
    }
    return found
  }

  private func files(named name: String, in parent: String, fields: String) async throws
    -> [DriveFile]
  {
    try await listed(
      "name = '\(DriveQuote(name).value())' and '\(DriveQuote(parent).value())' in parents "
        + "and mimeType != '\(DriveTree.folderType)' and trashed = false",
      fields: fields
    )
  }

  private func listed(_ query: String, fields: String) async throws -> [DriveFile] {
    try await DriveListing(api: api, query: query, fields: fields).files()
  }

  /// The moment as Drive writes it; empty when the text is not one.
  private func made(_ text: String) -> [Date] {
    let exact = ISO8601DateFormatter()
    exact.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    return (exact.date(from: text) ?? whole.date(from: text)).map { [$0] } ?? []
  }
}

/// The folders of a Drive that files are kept under, found or made level by level.
///
/// What it has found once it remembers, as folders are not expected to vanish
/// while the app runs; a folder deleted meanwhile makes requests fail until
/// the app starts again.
public actor DriveTree {
  static let folderType = "application/vnd.google-apps.folder"

  private let api: GoogleApi
  private let top: String
  private var known: [String: String] = [:]

  /// - Parameters:
  ///   - api: The Drive API of the user.
  ///   - top: Name of the folder at the top of the Drive that everything goes under.
  public init(api: GoogleApi, top: String) {
    self.api = api
    self.top = top
  }

  /// The identifier of the folder at the path below the top folder; "" is the top.
  ///
  /// - Parameter making: Whether missing folders are made; if not, a missing one gives empty.
  func folder(_ path: String, making: Bool) async throws -> [String] {
    if let id = known[path] {
      return [id]
    }
    var parent = "root"
    var walked = ""
    let levels = path.split(separator: "/").map(String.init)
    // The top folder is known by the empty path, each folder below by the path to it.
    for (depth, level) in ([top] + levels).enumerated() {
      walked = depth == 0 ? "" : levels.prefix(depth).joined(separator: "/")
      if let id = known[walked] {
        parent = id
        continue
      }
      let found = try await DriveListing(
        api: api,
        query: "name = '\(DriveQuote(level).value())' and '\(DriveQuote(parent).value())' "
          + "in parents and mimeType = '\(Self.folderType)' and trashed = false",
        fields: "id"
      ).files()
      if let id = found.first?.id {
        parent = id
      } else if making {
        parent = try await made(level, in: parent)
      } else {
        return []
      }
      known[walked] = parent
    }
    return [parent]
  }

  private func made(_ name: String, in parent: String) async throws -> String {
    let made = try await api.response(
      method: "POST",
      resource: "files",
      query: ["fields": "id"],
      json: try JSONEncoder().encode(NewFolder(name: name, parents: [parent]))
    )
    guard made.status == 200 else {
      throw CloudRefusal(step: "Folder \(name)", response: made)
    }
    return try JSONDecoder().decode(DriveFile.self, from: made.body).id
  }
}

/// All the files a Drive search finds, gathered page by page.
struct DriveListing {
  private let api: GoogleApi
  private let query: String
  private let fields: String

  init(api: GoogleApi, query: String, fields: String) {
    self.api = api
    self.query = query
    self.fields = fields
  }

  func files() async throws -> [DriveFile] {
    var all: [DriveFile] = []
    var page = ""
    repeat {
      var asked = [
        "q": query,
        "fields": "nextPageToken,files(\(fields))",
        "pageSize": "1000",
        "orderBy": "name",
        "spaces": "drive",
      ]
      if !page.isEmpty {
        asked["pageToken"] = page
      }
      let answer = try await api.response(method: "GET", resource: "files", query: asked)
      guard answer.status == 200 else {
        throw CloudRefusal(step: "Search of Google Drive", response: answer)
      }
      let listed = try JSONDecoder().decode(DrivePage.self, from: answer.body)
      all += listed.files
      page = listed.nextPageToken ?? ""
    } while !page.isEmpty
    return all
  }
}

/// A path below the folder files are kept under, split into its folder and its own name.
struct DrivePath {
  private let path: String

  init(_ path: String) {
    self.path = path
  }

  func folder() -> String {
    path.split(separator: "/").dropLast().joined(separator: "/")
  }

  func leaf() -> String {
    path.split(separator: "/").last.map(String.init) ?? path
  }
}

/// Text put between single quotes in a Drive search.
struct DriveQuote {
  private let text: String

  init(_ text: String) {
    self.text = text
  }

  func value() -> String {
    text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
  }
}

/// Drive holds nothing at the path.
public struct MissingOnDrive: LocalizedError, CustomStringConvertible, Verdict {
  private let name: String

  init(name: String) {
    self.name = name
  }

  public var description: String {
    "Google Drive holds no \(name)"
  }

  public var errorDescription: String? {
    description
  }

  /// The file may simply not have been filed away yet.
  public func stands() -> Bool {
    false
  }
}

// Codable requires readable stored properties; these only mirror Drive's JSON.
struct DriveFile: Decodable {
  let id: String
  let name: String
  let mimeType: String?
  let size: String?
  let md5Checksum: String?
  let modifiedTime: String?
  let thumbnailLink: String?

  private enum CodingKeys: String, CodingKey {
    case id, name, mimeType, size, md5Checksum, modifiedTime, thumbnailLink
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
    mimeType = try values.decodeIfPresent(String.self, forKey: .mimeType)
    size = try values.decodeIfPresent(String.self, forKey: .size)
    md5Checksum = try values.decodeIfPresent(String.self, forKey: .md5Checksum)
    modifiedTime = try values.decodeIfPresent(String.self, forKey: .modifiedTime)
    thumbnailLink = try values.decodeIfPresent(String.self, forKey: .thumbnailLink)
  }
}

private struct DrivePage: Decodable {
  let files: [DriveFile]
  let nextPageToken: String?
}

private struct NewFile: Encodable {
  let name: String
  let parents: [String]
}

private struct NewFolder: Encodable {
  let name: String
  let mimeType = DriveTree.folderType
  let parents: [String]
}
