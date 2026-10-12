import Foundation
import OffloadCore

/// One photo or video of the library, as the ranking shows it.
struct LibraryItem: Sized, Identifiable, Sendable {
  /// PhotoKit's local identifier; SwiftUI lists require a readable `id`.
  let id: String
  let name: String
  let video: Bool
  let seconds: Double
  let created: Date
  private let size: Int64
  private let local: Int64

  init(
    id: String,
    name: String,
    video: Bool,
    seconds: Double,
    created: Date,
    size: Int64,
    local: Int64
  ) {
    self.id = id
    self.name = name
    self.video = video
    self.seconds = seconds
    self.created = created
    self.size = size
    self.local = local
  }

  func bytes() -> Int64 {
    size
  }

  func onDevice() -> Int64 {
    local
  }
}
