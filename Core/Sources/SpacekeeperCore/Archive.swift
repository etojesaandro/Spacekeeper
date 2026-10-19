import Foundation

/// A cloud whose kept files can be looked through and fetched back.
public protocol Archive: Sendable {
  /// What lies in the folder at the path below the cloud's own folder; "" is the top.
  func shelf(_ path: String) async throws -> Shelf

  /// A small picture of the file, as image data.
  func thumbnail(of file: KeptFile) async throws -> Data

  /// A picture of the file large enough to fill a screen, as image data.
  func picture(of file: KeptFile) async throws -> Data

  /// Fetches the file's content into a place on the device.
  func fetched(_ file: KeptFile, into place: URL) async throws
}

/// What one folder of an archive holds.
public struct Shelf: Sendable, Equatable {
  private let inner: [String]
  private let files: [KeptFile]

  /// - Parameters:
  ///   - folders: Paths of the folders inside, below the cloud's own folder.
  ///   - files: The files inside.
  public init(folders: [String], files: [KeptFile]) {
    self.inner = folders
    self.files = files
  }

  /// Paths of the folders inside, below the cloud's own folder.
  public func folders() -> [String] {
    inner
  }

  /// The originals the files belong to, in the order of their names.
  ///
  /// Files of one original share the start of their names, the moment the
  /// original was made and a piece of its identifier; any other file counts
  /// as an original of its own.
  public func originals() -> [KeptOriginal] {
    var order: [String] = []
    var groups: [String: [KeptFile]] = [:]
    for file in files.sorted(by: { $0.id < $1.id }) {
      let key = KeptName(file.name()).key()
      if groups[key] == nil {
        order.append(key)
      }
      groups[key, default: []].append(file)
    }
    return order.map { KeptOriginal(files: groups[$0] ?? []) }
  }
}

/// One file an archive keeps.
public struct KeptFile: Sendable, Equatable, Identifiable {
  /// Its path below the cloud's own folder; lists require a readable `id`.
  public let id: String
  let bytes: Int64
  let print: Fingerprint
  let made: [Date]
  let preview: [URL]

  /// - Parameters:
  ///   - path: Its path below the cloud's own folder.
  ///   - bytes: Its size.
  ///   - print: Its fingerprint as the cloud reports it.
  ///   - made: When its original was made, if the cloud has it noted; else empty.
  ///   - preview: Where a small picture of it can be had; empty when nowhere.
  public init(path: String, bytes: Int64, print: Fingerprint, made: [Date], preview: [URL]) {
    self.id = path
    self.bytes = bytes
    self.print = print
    self.made = made
    self.preview = preview
  }

  /// Its size in bytes.
  public func weight() -> Int64 {
    bytes
  }

  /// Its name within its folder.
  public func name() -> String {
    id.split(separator: "/").last.map(String.init) ?? id
  }
}

/// The name of a kept file, read for what the app put into it.
struct KeptName {
  private let name: String

  init(_ name: String) {
    self.name = name
  }

  /// What the files of one original have in common: the start of the name
  /// up to the piece of the identifier, or the whole name of a foreign file.
  func key() -> String {
    String(name.prefix(lead()))
  }

  /// The name the file had in the photo library.
  func original() -> String {
    lead() < name.count ? String(name.dropFirst(lead() + 1)) : name
  }

  /// The moment written into the name, read in the given time zone; empty when there is none.
  func moment(in zone: TimeZone) -> [Date] {
    guard matches("####-##-##_##-##-##_") else {
      return []
    }
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = zone
    format.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return format.date(from: String(name.prefix(19))).map { [$0] } ?? []
  }

  /// How many characters the app's own start of the name takes, without the
  /// underscore that ends it; the whole length when the name is foreign.
  private func lead() -> Int {
    for mask in ["####-##-##_##-##-##_", "undated_"] where matches(mask) {
      let end = mask.count + 8
      let characters = Array(name)
      if characters.count > end + 1, characters[end] == "_",
        !characters[mask.count..<end].contains("_")
      {
        return end
      }
    }
    return name.count
  }

  /// Whether the name starts as the mask says, where "#" stands for a digit.
  private func matches(_ mask: String) -> Bool {
    guard name.count >= mask.count else {
      return false
    }
    return zip(name, mask).allSatisfy { letter, sign in
      sign == "#" ? letter.isASCII && letter.isNumber : letter == sign
    }
  }
}
