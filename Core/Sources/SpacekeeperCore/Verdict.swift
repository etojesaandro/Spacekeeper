import Foundation

/// An answer that settles the matter, as opposed to a passing trouble such
/// as a lost connection.
public protocol Verdict: Error {
  /// Whether asking again would get the same answer.
  func stands() -> Bool
}

extension Verdict {
  public func stands() -> Bool {
    true
  }
}
