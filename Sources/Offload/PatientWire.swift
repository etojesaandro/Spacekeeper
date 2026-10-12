import Foundation
import OffloadCore
import os

/// The network as this phone reaches it: it reports how far an upload has got,
/// and when a request fails it says which one, after how long and how far in.
///
/// Patience itself (how long to wait on a silent connection) is a property of
/// the session it is given.
struct PatientWire: Wire {
  private let session: URLSession
  private let progress: @Sendable (Int64, Int64) -> Void

  /// - Parameters:
  ///   - session: Session to send through.
  ///   - progress: Told how many bytes of how many an upload has sent.
  init(session: URLSession, progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.session = session
    self.progress = progress
  }

  func response(to request: Request) async throws -> Response {
    let started = Date()
    do {
      let (body, answer) = try await session.data(for: native(request))
      return try response(body: body, answer: answer)
    } catch {
      throw TransferFailure(
        what: "\(request.method) \(request.url.host() ?? "?")\(request.url.path())",
        seconds: Date().timeIntervalSince(started),
        progress: "",
        cause: error
      )
    }
  }

  func response(to request: Request, sending file: URL) async throws -> Response {
    let started = Date()
    let meter = Meter(progress)
    do {
      let (body, answer) = try await session.upload(
        for: native(request),
        fromFile: file,
        delegate: meter
      )
      return try response(body: body, answer: answer)
    } catch {
      throw TransferFailure(
        what: "Upload to \(request.url.host() ?? "?")",
        seconds: Date().timeIntervalSince(started),
        progress: meter.summary(),
        cause: error
      )
    }
  }

  private func native(_ request: Request) -> URLRequest {
    var native = URLRequest(url: request.url)
    native.httpMethod = request.method
    for (name, value) in request.headers {
      native.setValue(value, forHTTPHeaderField: name)
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

/// A request did not get an answer.
struct TransferFailure: LocalizedError {
  private let what: String
  private let seconds: Double
  private let progress: String
  private let cause: any Error

  init(what: String, seconds: Double, progress: String, cause: any Error) {
    self.what = what
    self.seconds = seconds
    self.progress = progress
    self.cause = cause
  }

  var errorDescription: String? {
    "\(what) failed after \(Int(seconds.rounded())) s"
      + (progress.isEmpty ? "" : ", \(progress)")
      + ": \(cause.localizedDescription)"
  }
}

/// Counts the bytes one upload has sent; URLSession reports them through a delegate object.
private final class Meter: NSObject, URLSessionTaskDelegate, Sendable {
  private let progress: @Sendable (Int64, Int64) -> Void
  private let counts = OSAllocatedUnfairLock(initialState: (sent: Int64(0), total: Int64(0)))

  init(_ progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.progress = progress
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    // Told once per whole percent, as URLSession reports every few kilobytes.
    let moved = counts.withLock { counts in
      let before = counts.total > 0 ? counts.sent * 100 / counts.total : -1
      counts = (totalBytesSent, totalBytesExpectedToSend)
      return before != totalBytesSent * 100 / max(totalBytesExpectedToSend, 1)
    }
    if moved {
      progress(totalBytesSent, totalBytesExpectedToSend)
    }
  }

  func summary() -> String {
    let (sent, total) = counts.withLock { $0 }
    return "\(sent.formatted(.byteCount(style: .file))) of "
      + "\(total.formatted(.byteCount(style: .file))) sent"
  }
}
