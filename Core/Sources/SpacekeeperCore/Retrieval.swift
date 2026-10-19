import Foundation

/// The return of one kept original from an archive to the photo library.
///
/// Each file is fetched and checked against the fingerprint the cloud
/// reports before the library is handed anything, so a download cut short
/// or damaged on the way never ends up among the photos.
public struct Retrieval: Sendable {
  private let original: KeptOriginal
  private let archive: any Archive
  private let gallery: any Gallery
  private let folder: URL

  /// - Parameters:
  ///   - original: What to bring back.
  ///   - archive: Where it is kept.
  ///   - gallery: The photo library that takes it.
  ///   - folder: Where its files are put on the way; it must belong to this retrieval alone.
  public init(
    of original: KeptOriginal,
    from archive: any Archive,
    into gallery: any Gallery,
    through folder: URL
  ) {
    self.original = original
    self.archive = archive
    self.gallery = gallery
    self.folder = folder
  }

  /// Fetches the files, checks them and hands them to the library.
  ///
  /// Returning without an error means the library has the original again.
  public func make() async throws {
    let parts = original.parts()
    guard !parts.isEmpty else {
      throw NothingToRestore(name: original.name())
    }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: folder)
    }
    var fetched: [FetchedPart] = []
    for (index, part) in parts.enumerated() {
      // A folder each, as two files of one original may share a name.
      let place = folder.appendingPathComponent("\(index)")
      try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
      let file = place.appendingPathComponent(part.name())
      try await archive.fetched(part.file, into: file)
      let local = try FingerprintOf(file).value()
      guard local == part.file.print else {
        throw FetchMismatch(name: part.name(), local: local, remote: part.file.print)
      }
      fetched.append(FetchedPart(role: part.role, file: file, name: part.name()))
    }
    try await gallery.take(fetched, made: original.noted())
  }
}

/// A photo library as the place originals come back to.
public protocol Gallery: Sendable {
  /// Takes the files as one item, made at the given moment if one is given.
  func take(_ parts: [FetchedPart], made: [Date]) async throws
}

/// A fetched file together with the part it plays and the name it had in the library.
public struct FetchedPart: Sendable, Equatable {
  public let role: Role
  public let file: URL
  public let name: String
}

/// A kept original has no file a photo library would take.
public struct NothingToRestore: LocalizedError, CustomStringConvertible {
  private let name: String

  init(name: String) {
    self.name = name
  }

  public var description: String {
    "\(name) is neither a photo nor a video, so the photo library cannot take it"
  }

  public var errorDescription: String? {
    description
  }
}

/// What was downloaded is not what the cloud says it keeps.
public struct FetchMismatch: LocalizedError, CustomStringConvertible {
  private let name: String
  private let local: Fingerprint
  private let remote: Fingerprint

  init(name: String, local: Fingerprint, remote: Fingerprint) {
    self.name = name
    self.local = local
    self.remote = remote
  }

  public var description: String {
    "The download of \(name) differs from what the cloud keeps: got \(local), expected \(remote)"
  }

  public var errorDescription: String? {
    description
  }
}
