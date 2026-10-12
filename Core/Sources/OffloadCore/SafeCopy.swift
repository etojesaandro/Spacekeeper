import Foundation

/// A copy of one original in a cloud, proven identical file by file.
public struct SafeCopy: Sendable {
  private let original: any Original
  private let cloud: any Cloud

  public init(of original: any Original, in cloud: any Cloud) {
    self.original = original
    self.cloud = cloud
  }

  /// Uploads every file of the original and checks each against what the cloud reports.
  ///
  /// Returning without an error means the cloud holds all of it.
  public func make() async throws {
    let parts = try await original.parts()
    guard !parts.isEmpty else {
      throw NothingToOffload()
    }
    for part in parts {
      let local = try FingerprintOf(part.file).value()
      let remote = try await cloud.kept(part.file, as: part.name)
      guard remote == local else {
        throw CopyMismatch(name: part.name, local: local, remote: remote)
      }
    }
  }
}

/// The cloud holds something other than what was sent.
public struct CopyMismatch: LocalizedError, CustomStringConvertible {
  private let name: String
  private let local: Fingerprint
  private let remote: Fingerprint

  init(name: String, local: Fingerprint, remote: Fingerprint) {
    self.name = name
    self.local = local
    self.remote = remote
  }

  public var description: String {
    "Cloud copy of \(name) differs from the original: sent \(local), cloud holds \(remote)"
  }

  public var errorDescription: String? {
    description
  }
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
