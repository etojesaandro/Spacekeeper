import Foundation

/// The phone as a computer sees it when backing up its photo library.
public protocol Handset: Sendable {
  /// Every item of the photo library.
  func items() async throws -> [MediaItem]

  /// The files the item is stored as.
  func pieces(of item: MediaItem) async throws -> [Piece]

  /// Fetches one file of the item into a place on the computer.
  ///
  /// - Returns: The fingerprint of what the phone sent, as the phone counted it.
  func fetched(_ piece: Piece, of item: MediaItem, into file: URL) async throws -> Fingerprint

  /// Tells the phone which items the computer safely holds.
  func told(holding items: [MediaItem]) async throws
}

/// One file of a library item as the phone offers it.
public struct Piece: Codable, Sendable, Equatable {
  public let index: Int
  public let path: String
  public let taken: Date

  /// - Parameters:
  ///   - index: Its place among the files of its item, counted from zero.
  ///   - path: Where a backup keeps it, below the backup's folder.
  ///   - taken: When the original was made.
  public init(index: Int, path: String, taken: Date) {
    self.index = index
    self.path = path
    self.taken = taken
  }
}

/// How far a backup reaches into what the phone has.
public enum Reach: Sendable, Equatable {
  /// Only what lies on the phone itself.
  case device

  /// Also what the phone has to fetch from iCloud first.
  case everything
}
