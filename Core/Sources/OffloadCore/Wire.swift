import Foundation

/// The network as cloud clients see it: a request goes out, a response comes back.
///
/// Logging, retries and background transfer are meant to be layered on
/// as decorators of this protocol.
public protocol Wire: Sendable {
  /// Sends a request whose body, if any, is held in memory.
  func response(to request: Request) async throws -> Response

  /// Sends a request whose body is streamed from a file on disk.
  func response(to request: Request, sending file: URL) async throws -> Response
}

/// An HTTP request reduced to what cloud clients need.
public struct Request: Sendable, Equatable {
  public let method: String
  public let url: URL
  public let headers: [String: String]
  public let body: Data

  /// - Parameters:
  ///   - method: HTTP method.
  ///   - url: Address to send to.
  ///   - headers: HTTP headers.
  ///   - body: What is sent along; empty for nothing.
  public init(method: String, url: URL, headers: [String: String], body: Data) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
  }

  /// A request that sends nothing along.
  public init(method: String, url: URL, headers: [String: String]) {
    self.init(method: method, url: url, headers: headers, body: Data())
  }
}

/// An HTTP response reduced to what cloud clients need.
public struct Response: Sendable {
  public let status: Int
  public let body: Data

  public init(status: Int, body: Data) {
    self.status = status
    self.body = body
  }
}
