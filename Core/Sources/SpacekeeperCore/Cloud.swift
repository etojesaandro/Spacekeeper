import Foundation

/// A cloud storage that keeps copies of files taken off the device.
public protocol Cloud: Sendable {
  /// Uploads the file under the given name.
  ///
  /// - Returns: Fingerprint of the copy as the cloud itself reports it.
  func kept(_ file: URL, as name: String) async throws -> Fingerprint
}

/// A cloud answered a request with something other than success.
public struct CloudRefusal: LocalizedError, CustomStringConvertible, Verdict {
  private let step: String
  private let response: Response

  init(step: String, response: Response) {
    self.step = step
    self.response = response
  }

  public var description: String {
    "\(step) refused with HTTP \(response.status): "
      + String(decoding: response.body, as: UTF8.self)
  }

  public var errorDescription: String? {
    description
  }

  /// A locked file, too many requests or a failing server may answer differently later.
  public func stands() -> Bool {
    response.status < 500 && response.status != 423 && response.status != 429
      && !RateLimited(response).value()
  }
}

/// Whether an answer of HTTP 403 means too many requests rather than no access.
///
/// Google Drive tells that a user or the app asked too often with 403, not
/// 429, and names the reason in the body; such a refusal passes with time.
struct RateLimited {
  private let response: Response

  init(_ response: Response) {
    self.response = response
  }

  func value() -> Bool {
    response.status == 403
      && String(decoding: response.body, as: UTF8.self).lowercased().contains("ratelimitexceeded")
  }
}
