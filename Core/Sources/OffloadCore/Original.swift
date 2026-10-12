import Foundation

/// An original photo or video living on the device.
///
/// One original may be stored as several files: a Live Photo is a picture
/// and a clip, an edited photo keeps both the untouched and the edited image.
public protocol Original: Sendable {
  /// Its full-quality content as files on disk, ready to upload.
  func parts() async throws -> [Part]

  /// Removes it from the device.
  func remove() async throws
}

/// One file of an original together with the name its copy carries in a cloud.
public struct Part: Sendable, Equatable {
  public let name: String
  public let file: URL

  public init(name: String, file: URL) {
    self.name = name
    self.file = file
  }
}
