import Foundation
import OffloadCore

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
