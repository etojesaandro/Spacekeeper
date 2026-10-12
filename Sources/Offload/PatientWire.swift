import Foundation
import OffloadCore
import os

/// The network as this phone reaches it.
///
/// It says which request it is making and how far an upload has got, writes
/// the same to the system log, and when a request fails it tells which one,
/// after how long and how far in. Short questions get half a minute; an
/// upload may stay silent for ten minutes, or longer for a very large file,
/// because the Disk goes quiet while it files the upload away.
struct PatientWire: Wire {
  private let session: URLSession
  private let say: @Sendable (String) -> Void
  private let log = Logger(subsystem: "Offload", category: "wire")

  /// - Parameters:
  ///   - session: Session to send through.
  ///   - say: Told, in words for the user, what is happening.
  init(session: URLSession, say: @escaping @Sendable (String) -> Void) {
    self.session = session
    self.say = say
  }

  func response(to request: Request) async throws -> Response {
    let what = "\(request.method) \(request.url.host() ?? "?")\(request.url.path())"
    let started = Date()
    var native = native(request)
    native.timeoutInterval = 30
    say("Yandex Disk: \(request.method) \(request.url.lastPathComponent)")
    log.notice("start \(what, privacy: .public)")
    do {
      let (body, answer) = try await session.data(for: native)
      let response = try response(body: body, answer: answer)
      log.notice(
        "done \(what, privacy: .public) status \(response.status) in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s"
      )
      return response
    } catch {
      log.error("failed \(what, privacy: .public): \(error.localizedDescription, privacy: .public)")
      throw TransferFailure(
        what: what,
        seconds: Date().timeIntervalSince(started),
        progress: "",
        cause: error
      )
    }
  }

  func response(to request: Request, sending file: URL) async throws -> Response {
    let what = "Upload to \(request.url.host() ?? "?")"
    let started = Date()
    let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?
      .int64Value ?? 0
    var native = native(request)
    // The Disk stays silent after the last byte for roughly two minutes per gigabyte.
    native.timeoutInterval = max(600, Double(size) / 1_073_741_824 * 180)
    let meter = Meter(say: say, log: log)
    say("Connecting to \(request.url.host() ?? "Yandex Disk")")
    log.notice("start \(what, privacy: .public), \(size) bytes")
    do {
      let (body, answer) = try await session.upload(for: native, fromFile: file, delegate: meter)
      let response = try response(body: body, answer: answer)
      log.notice(
        "done \(what, privacy: .public) status \(response.status) in \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) s"
      )
      return response
    } catch {
      log.error(
        "failed \(what, privacy: .public), \(meter.summary(), privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      throw TransferFailure(
        what: what,
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
  private let say: @Sendable (String) -> Void
  private let log: Logger
  private let counts = OSAllocatedUnfairLock(initialState: (sent: Int64(0), total: Int64(0)))

  init(say: @escaping @Sendable (String) -> Void, log: Logger) {
    self.say = say
    self.log = log
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
      log.notice("sent \(totalBytesSent) of \(totalBytesExpectedToSend) bytes")
      say(
        totalBytesSent < totalBytesExpectedToSend
          ? "Uploading: \(totalBytesSent.formatted(.byteCount(style: .file))) of "
            + "\(totalBytesExpectedToSend.formatted(.byteCount(style: .file)))"
          : "Sent. Waiting for Yandex Disk to confirm"
      )
    }
  }

  func summary() -> String {
    let (sent, total) = counts.withLock { $0 }
    return "\(sent.formatted(.byteCount(style: .file))) of "
      + "\(total.formatted(.byteCount(style: .file))) sent"
  }
}
