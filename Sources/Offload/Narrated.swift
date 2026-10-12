import Foundation
import OffloadCore

/// An original that says what it is about to do before doing it.
struct NarratedOriginal: Original {
  private let origin: any Original
  private let say: @Sendable (String) -> Void

  init(_ origin: any Original, say: @escaping @Sendable (String) -> Void) {
    self.origin = origin
    self.say = say
  }

  func parts() async throws -> [Part] {
    say("Preparing the original")
    return try await origin.parts()
  }

  func remove() async throws {
    say("Waiting for your permission to delete")
    try await origin.remove()
  }
}

/// A cloud that says what it is about to do before doing it.
struct NarratedCloud: Cloud {
  private let origin: any Cloud
  private let say: @Sendable (String) -> Void

  init(_ origin: any Cloud, say: @escaping @Sendable (String) -> Void) {
    self.origin = origin
    self.say = say
  }

  func kept(_ file: URL, as name: String) async throws -> Fingerprint {
    say("Uploading and verifying \(name)")
    return try await origin.kept(file, as: name)
  }
}
