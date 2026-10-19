import Foundation

/// One original on its way to a cloud, as one or more files.
///
/// A Live Photo is a picture and a clip, an edited photo keeps both the
/// untouched and the edited image; the original may leave the device only
/// when the cloud holds every one of them.
public struct Consignment: Codable, Sendable, Equatable, Identifiable {
  private let item: MediaItem
  private let stamp: Date
  private let parcels: [Parcel]
  private let aim: Aim

  /// - Parameters:
  ///   - item: The library item the files belong to.
  ///   - stamp: When the library last changed the item, read as its files were taken.
  ///   - parcels: Its files; there must be at least one.
  ///   - aim: What is to become of the original once the cloud holds it.
  public init(item: MediaItem, stamp: Date, parcels: [Parcel], aim: Aim) throws {
    guard !parcels.isEmpty else {
      throw NothingToOffload()
    }
    self.item = item
    self.stamp = stamp
    self.parcels = parcels
    self.aim = aim
  }

  /// Whether the original is to leave the device once the cloud holds it.
  public func leaves() -> Bool {
    aim == .move
  }

  /// The library's identifier of the item; lists require a readable `id`.
  public var id: String {
    item.id
  }

  /// The library item this is a copy of.
  public func original() -> MediaItem {
    item
  }

  /// Whether the item last changed at the given time is still the one that was copied.
  public func unchanged(since changed: Date) -> Bool {
    stamp == changed
  }

  /// Where it stands as a whole.
  public func standing() -> Standing {
    for parcel in parcels {
      if case .failed(let reason) = parcel.leg {
        return .failed(reason)
      }
    }
    return parcels.allSatisfy { $0.leg == .safe } ? .safe : .travelling
  }

  /// Bytes of all its files.
  public func bytes() -> Int64 {
    parcels.reduce(0) { $0 + $1.bytes }
  }

  /// Bytes that have reached the cloud, given how much of each file being sent has gone.
  public func gone(sent: [String: Int64]) -> Int64 {
    parcels.reduce(0) { $0 + $1.gone(sent: sent[$1.name] ?? 0) }
  }

  /// Its files.
  func files() -> [Parcel] {
    parcels
  }

  /// The same consignment with each file replaced by what the change makes of it.
  func with(_ change: (Parcel) -> Parcel) -> Consignment {
    // The files were checked when the consignment was first made.
    Consignment(item: item, stamp: stamp, checked: parcels.map(change), aim: aim)
  }

  private init(item: MediaItem, stamp: Date, checked parcels: [Parcel], aim: Aim) {
    self.item = item
    self.stamp = stamp
    self.parcels = parcels
    self.aim = aim
  }
}

/// What is to become of an original once the cloud holds a copy of it.
public enum Aim: Codable, Sendable, Equatable {
  /// It leaves the device.
  case move

  /// It stays on the device as well.
  case copy
}

/// Where a consignment stands as a whole.
public enum Standing: Sendable, Equatable {
  /// Some of its files are not yet proven to be in the cloud.
  case travelling

  /// The cloud holds an identical copy of every file.
  case safe

  /// A file could not be stored, for the reason given.
  case failed(String)
}

/// One file of a consignment.
public struct Parcel: Codable, Sendable, Equatable {
  let name: String
  let file: String
  let bytes: Int64
  let print: Fingerprint
  let taken: Date
  let leg: Leg
  let sends: Int

  /// - Parameters:
  ///   - name: The path its copy takes in the cloud; no two parcels may share it.
  ///   - file: Where it waits, as a path below the outbox's folder.
  ///   - bytes: Its size.
  ///   - print: Its fingerprint.
  ///   - taken: When the original was made.
  public init(name: String, file: String, bytes: Int64, print: Fingerprint, taken: Date) {
    self.init(
      name: name,
      file: file,
      bytes: bytes,
      print: print,
      taken: taken,
      leg: .staged,
      sends: 0
    )
  }

  init(
    name: String,
    file: String,
    bytes: Int64,
    print: Fingerprint,
    taken: Date,
    leg: Leg,
    sends: Int
  ) {
    self.name = name
    self.file = file
    self.bytes = bytes
    self.print = print
    self.taken = taken
    self.leg = leg
    self.sends = sends
  }

  /// The same file on another leg of its way, with this many sendings behind it.
  private func moved(to leg: Leg, after sends: Int) -> Parcel {
    Parcel(
      name: name,
      file: file,
      bytes: bytes,
      print: print,
      taken: taken,
      leg: leg,
      sends: sends
    )
  }

  /// The same file on another leg of its way.
  func on(_ leg: Leg) -> Parcel {
    moved(to: leg, after: sends)
  }

  /// The same file after one more sending has started.
  func sent() -> Parcel {
    moved(to: .sent, after: sends + 1)
  }

  /// The same file waiting to be sent, with this many sendings behind it.
  func waiting(after sends: Int) -> Parcel {
    moved(to: .staged, after: max(sends, 0))
  }

  /// Bytes that have reached the cloud, given how much of the current sending has gone.
  func gone(sent: Int64) -> Int64 {
    switch leg {
    case .delivered, .safe:
      return bytes
    case .sent:
      return min(max(sent, 0), bytes)
    case .staged, .failed:
      return 0
    }
  }
}

/// How far a file has got.
enum Leg: Codable, Sendable, Equatable {
  /// Waiting on the device to be sent.
  case staged

  /// Handed over for sending.
  case sent

  /// Taken by the cloud, but not yet proven identical.
  case delivered

  /// The cloud holds an identical copy.
  case safe

  /// It could not be stored, for the reason given.
  case failed(String)
}

/// An original offered no files, so removing it would lose it without a copy.
public struct NothingToOffload: LocalizedError, CustomStringConvertible {
  init() {}

  public var description: String {
    "The original has no files to upload, so it was left in place"
  }

  public var errorDescription: String? {
    description
  }
}
