import Foundation

/// A cloud that takes a file in separate steps.
///
/// The app asks where to send the file, something else does the sending,
/// and later the app asks what the cloud holds. Nothing ties the steps to
/// one run of the app, so the sending can be left to the system and survive
/// the app being closed.
public protocol Depot: Sendable {
  /// The request that carries a file of the given size to be stored under the name.
  func door(for name: String, bytes: Int64) async throws -> Request

  /// The fingerprint of what the cloud holds under the name, after finishing
  /// whatever filing an arrived file still needs; empty when it holds nothing.
  func shelved(_ name: String) async throws -> [Fingerprint]
}
