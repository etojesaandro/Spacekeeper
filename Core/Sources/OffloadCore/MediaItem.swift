import Foundation

/// One photo or video of the library, as the ranking shows it.
public struct MediaItem: Sized, Identifiable, Sendable, Codable, Equatable {
  /// The library's identifier of the item; lists require a readable `id`.
  public let id: String
  public let name: String
  public let video: Bool
  public let seconds: Double
  public let created: Date
  private let modified: Date
  private let size: Int64
  private let local: Int64

  /// - Parameters:
  ///   - id: The library's identifier of the item.
  ///   - name: Its original filename.
  ///   - video: Whether it is a video rather than a photo.
  ///   - seconds: Its playing time, zero for a photo.
  ///   - created: When it was taken.
  ///   - modified: When the library last changed it.
  ///   - size: Bytes of everything stored for it.
  ///   - local: How many of those bytes sit on the device.
  public init(
    id: String,
    name: String,
    video: Bool,
    seconds: Double,
    created: Date,
    modified: Date,
    size: Int64,
    local: Int64
  ) {
    self.id = id
    self.name = name
    self.video = video
    self.seconds = seconds
    self.created = created
    self.modified = modified
    self.size = size
    self.local = local
  }

  public func bytes() -> Int64 {
    size
  }

  public func onDevice() -> Int64 {
    local
  }

  /// Whether what is known here still describes an item last changed at the given time.
  public func unchanged(since changed: Date) -> Bool {
    modified == changed
  }
}
