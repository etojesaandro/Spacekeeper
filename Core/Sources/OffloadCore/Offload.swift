import Foundation

/// Moving one original to a cloud.
///
/// The original is removed from the device only after the cloud reports, for
/// every one of its files, a copy with the same fingerprint; any failure
/// before that leaves it in place.
public struct Offload: Sendable {
  private let original: any Original
  private let cloud: any Cloud

  public init(of original: any Original, to cloud: any Cloud) {
    self.original = original
    self.cloud = cloud
  }

  /// Uploads, verifies and then removes the original.
  public func run() async throws {
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
    try await original.remove()
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
