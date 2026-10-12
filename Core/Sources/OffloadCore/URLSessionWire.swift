import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The real network, reached through `URLSession`.
public struct URLSessionWire: Wire {
  private let session: URLSession

  public init(session: URLSession) {
    self.session = session
  }

  /// Uses the shared session.
  public init() {
    self.init(session: .shared)
  }

  public func response(to request: Request) async throws -> Response {
    let (body, answer) = try await session.data(for: native(request))
    return try response(body: body, answer: answer)
  }

  public func response(to request: Request, sending file: URL) async throws -> Response {
    let (body, answer) = try await session.upload(for: native(request), fromFile: file)
    return try response(body: body, answer: answer)
  }

  private func native(_ request: Request) -> URLRequest {
    var native = URLRequest(url: request.url)
    native.httpMethod = request.method
    for (name, value) in request.headers {
      native.setValue(value, forHTTPHeaderField: name)
    }
    if !request.body.isEmpty {
      native.httpBody = request.body
    }
    return native
  }

  private func response(body: Data, answer: URLResponse) throws -> Response {
    guard let http = answer as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    return Response(status: http.statusCode, body: body)
  }
}
