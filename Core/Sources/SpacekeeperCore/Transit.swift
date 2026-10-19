import Foundation

/// What carries files to a cloud, possibly while the app is not running.
///
/// How a sending ended is not answered here: whoever owns the transit is
/// told about it and passes the word on to the outbox.
public protocol Transit: Sendable {
  /// Starts sending the file with the request, under a tag to know it by later.
  func send(_ file: URL, through request: Request, tagged tag: String) async throws

  /// Tags of the files still being sent.
  func underway() async -> Set<String>

  /// Calls off the sending of the files with these tags.
  func recall(_ tags: Set<String>) async
}
