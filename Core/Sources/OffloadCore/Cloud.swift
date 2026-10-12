import Foundation

/// A cloud storage that keeps copies of files taken off the device.
public protocol Cloud: Sendable {
  /// Uploads the file under the given name.
  ///
  /// - Returns: Fingerprint of the copy as the cloud itself reports it.
  func kept(_ file: URL, as name: String) async throws -> Fingerprint
}

/// A cloud answered a request with something other than success.
public struct CloudRefusal: LocalizedError, CustomStringConvertible {
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
}
