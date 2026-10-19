import Foundation

/// A backup of the phone's photo library into a folder of a computer.
///
/// It fetches what the folder does not hold yet, so running it again brings
/// only what is new or changed. A file counts as held once what arrived has
/// the fingerprint of what the phone sent; until then it lies beside its
/// place under another name and never passes for a finished copy.
public struct Backup: Sendable {
  private let handset: any Handset
  private let folder: URL
  private let ledger: Ledger
  private let reach: Reach
  private let onlooker: any BackupOnlooker
  private let giveUp: Int

  /// - Parameters:
  ///   - handset: The phone.
  ///   - folder: Where the backup is kept.
  ///   - ledger: What remembers the items the folder holds.
  ///   - reach: Whether items that are only in iCloud are fetched as well.
  ///   - onlooker: Told how the backup is getting on.
  ///   - giveUp: How many items may fail in a row before the phone counts as gone.
  public init(
    from handset: any Handset,
    into folder: URL,
    ledger: Ledger,
    reach: Reach,
    watched onlooker: any BackupOnlooker,
    giveUp: Int
  ) {
    self.handset = handset
    self.folder = folder
    self.ledger = ledger
    self.reach = reach
    self.onlooker = onlooker
    self.giveUp = giveUp
  }

  /// Brings the folder up to date and tells the phone what it holds.
  public func run() async throws -> BackupReport {
    let items = try await handset.items()
    var known = ledger.entries()
    var held: [MediaItem] = []
    var copied: [MediaItem] = []
    var away = 0
    var failed: [String] = []
    var streak = 0
    for (number, item) in items.enumerated() where streak < giveUp {
      if let entry = known[item.id], entry.matches(item, in: folder) {
        held.append(item)
        continue
      }
      if reach == .device, item.onDevice() < item.bytes() {
        away += 1
        continue
      }
      onlooker.copying(number + 1, of: items.count, item)
      do {
        known[item.id] = try await copy(of: item)
        held.append(item)
        copied.append(item)
        streak = 0
        if copied.count % 20 == 0 {
          try ledger.keep(known)
        }
      } catch {
        streak += 1
        failed.append("\(item.name): \(error.localizedDescription)")
        onlooker.failed(item, error.localizedDescription)
      }
    }
    try ledger.keep(known)
    if streak < giveUp {
      try await handset.told(holding: held)
    }
    return BackupReport(
      copied: copied,
      present: held.count - copied.count,
      away: away,
      failed: failed,
      broken: streak >= giveUp
    )
  }

  /// Fetches every file of an item into its place.
  private func copy(of item: MediaItem) async throws -> Held {
    let pieces = try await handset.pieces(of: item)
    guard !pieces.isEmpty else {
      throw NothingToOffload()
    }
    var files: [HeldFile] = []
    for piece in pieces {
      let path = try PortablePath(piece.path).value()
      let place = folder.appendingPathComponent(path)
      let arriving = place.appendingPathExtension("part")
      try FileManager.default.createDirectory(
        at: place.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      defer {
        try? FileManager.default.removeItem(at: arriving)
      }
      let sent = try await handset.fetched(piece, of: item, into: arriving)
      let arrived = try FingerprintOf(arriving).value()
      guard arrived == sent else {
        throw FetchMismatch(name: piece.path, local: arrived, remote: sent)
      }
      try? FileManager.default.removeItem(at: place)
      try FileManager.default.moveItem(at: arriving, to: place)
      if piece.taken != .distantPast {
        try FileManager.default.setAttributes(
          [.modificationDate: piece.taken],
          ofItemAtPath: place.path
        )
        // Windows and macOS keep a creation date too; Linux has none to set.
        try? FileManager.default.setAttributes(
          [.creationDate: piece.taken],
          ofItemAtPath: place.path
        )
      }
      let facts = try FileManager.default.attributesOfItem(atPath: place.path)
      files.append(HeldFile(path: path, bytes: (facts[.size] as? NSNumber)?.int64Value ?? 0))
    }
    return Held(item: item, files: files)
  }
}

/// Someone who wants to know how a backup is getting on.
public protocol BackupOnlooker: Sendable {
  /// The backup starts fetching the item with this number of so many.
  func copying(_ number: Int, of count: Int, _ item: MediaItem)

  /// An item could not be fetched, for the reason given.
  func failed(_ item: MediaItem, _ reason: String)
}

/// What a backup run did.
public struct BackupReport: Sendable, Equatable {
  /// The items fetched in this run.
  public let copied: [MediaItem]

  /// How many items the folder held already.
  public let present: Int

  /// How many items were left out because they are only in iCloud.
  public let away: Int

  /// The items that could not be fetched, each with the reason.
  public let failed: [String]

  /// Whether the run stopped early because the phone stopped answering.
  public let broken: Bool
}

/// What remembers, in a file, the items a backup folder holds.
public struct Ledger: Sendable {
  private let file: URL

  /// - Parameter file: Where the entries are kept; it need not exist yet.
  public init(file: URL) {
    self.file = file
  }

  /// The entries kept, by item identifier; none when nothing readable is kept.
  public func entries() -> [String: Held] {
    guard
      let data = try? Data(contentsOf: file),
      let entries = try? JSONDecoder().decode([String: Held].self, from: data)
    else {
      return [:]
    }
    return entries
  }

  /// Keeps the entries, replacing those kept before.
  public func keep(_ entries: [String: Held]) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try JSONEncoder().encode(entries).write(to: file, options: .atomic)
  }
}

/// One library item as a backup folder holds it.
public struct Held: Codable, Sendable, Equatable {
  private let item: MediaItem
  private let files: [HeldFile]

  init(item: MediaItem, files: [HeldFile]) {
    self.item = item
    self.files = files
  }

  /// Whether the folder still holds the item just as the phone has it now.
  func matches(_ now: MediaItem, in folder: URL) -> Bool {
    item == now
      && files.allSatisfy { file in
        let facts = try? FileManager.default.attributesOfItem(
          atPath: folder.appendingPathComponent(file.path).path
        )
        return (facts?[.size] as? NSNumber)?.int64Value == file.bytes
      }
  }
}

/// One file of a held item: where it lies and how big it is.
struct HeldFile: Codable, Sendable, Equatable {
  let path: String
  let bytes: Int64
}

/// A place below a backup's folder, named so that Windows, macOS and Linux all accept it.
///
/// The same folder may be carried from one computer to another, so the names
/// are the same everywhere: a letter that Windows forbids in a file name
/// becomes an underscore, and so does a name's last dot or space, which
/// Windows drops. A backslash is a letter like that, so no level can climb out.
struct PortablePath {
  private let path: String

  /// - Parameter path: Levels separated by slashes, as the phone names them.
  init(_ path: String) {
    self.path = path
  }

  /// The path to use, with slashes between its levels.
  ///
  /// - Throws: `UnsafePath` when the path would lead outside the folder.
  func value() throws -> String {
    let forbidden = Set("<>:\"\\|?*")
    let levels = path.split(separator: "/", omittingEmptySubsequences: false).map { level in
      var name = String(
        level.map { forbidden.contains($0) || $0.asciiValue.map { $0 < 32 } == true ? "_" : $0 }
      )
      if let last = name.last, last == "." || last == " ", name != "..", name != "." {
        name = String(name.dropLast()) + "_"
      }
      return name
    }
    guard !levels.contains(".."), !levels.contains("."), !levels.contains("") else {
      throw UnsafePath(path: path)
    }
    return levels.joined(separator: "/")
  }
}

/// The phone named a place for a file that lies outside the backup's folder.
public struct UnsafePath: LocalizedError, CustomStringConvertible {
  private let path: String

  init(path: String) {
    self.path = path
  }

  public var description: String {
    "The phone asked to store a file at \(path), which is outside the backup folder"
  }

  public var errorDescription: String? {
    description
  }
}
