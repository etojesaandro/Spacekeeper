import Foundation
import SpacekeeperCore
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
  private let log = Logger(subsystem: "Spacekeeper", category: "wire")

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
    say(String(localized: "Asking the cloud"))
    log.notice("start \(what, privacy: .private(mask: .hash))")
    do {
      let (body, answer) = try await session.data(for: native)
      let response = try response(body: body, answer: answer)
      let took = Date().timeIntervalSince(started)
      log.notice(
        """
        done \(what, privacy: .private(mask: .hash)) status \(response.status) \
        in \(took, format: .fixed(precision: 1)) s
        """
      )
      return response
    } catch {
      log.error("failed \(what, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)")
      throw TransferFailure(
        what: what,
        seconds: Date().timeIntervalSince(started),
        progress: "",
        cause: error
      )
    }
  }

  func response(to request: Request, sending file: URL) async throws -> Response {
    let what = String(localized: "Upload to \(request.url.host() ?? "?")")
    let started = Date()
    let facts = try? FileManager.default.attributesOfItem(atPath: file.path)
    let size = (facts?[.size] as? NSNumber)?.int64Value ?? 0
    var native = native(request)
    // The Disk stays silent after the last byte for roughly two minutes per gigabyte.
    native.timeoutInterval = max(600, Double(size) / 1_073_741_824 * 180)
    let meter = Meter(say: say, log: log)
    say(String(localized: "Connecting to \(request.url.host() ?? String(localized: "the cloud"))"))
    log.notice("start \(what, privacy: .private(mask: .hash)), \(size) bytes")
    do {
      let (body, answer) = try await session.upload(for: native, fromFile: file, delegate: meter)
      let response = try response(body: body, answer: answer)
      let took = Date().timeIntervalSince(started)
      log.notice(
        """
        done \(what, privacy: .private(mask: .hash)) status \(response.status) \
        in \(took, format: .fixed(precision: 1)) s
        """
      )
      return response
    } catch {
      let (sent, why) = (meter.summary(), error.localizedDescription)
      log.error(
        "failed \(what, privacy: .private(mask: .hash)), \(sent, privacy: .public): \(why, privacy: .public)"
      )
      throw TransferFailure(
        what: what,
        seconds: Date().timeIntervalSince(started),
        progress: meter.summary(),
        cause: error
      )
    }
  }

  func response(to request: Request, saving file: URL) async throws -> Response {
    let what = String(localized: "Download from \(request.url.host() ?? "?")")
    let started = Date()
    var native = native(request)
    native.timeoutInterval = 600
    let flight = Flight()
    say(String(localized: "Connecting to \(request.url.host() ?? String(localized: "the cloud"))"))
    log.notice("start \(what, privacy: .private(mask: .hash))")
    // A download reports no progress to those who wait for it, so it is asked now and then.
    let say = say
    let ticker = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(500))
        let (got, all) = flight.progress()
        if all > 0 {
          say(
            String(
              localized: "Downloading: \(got.formatted(.byteCount(style: .file))) of \(all.formatted(.byteCount(style: .file)))"
            )
          )
        }
      }
    }
    defer {
      ticker.cancel()
    }
    do {
      let session = session
      let response: Response = try await withCheckedThrowingContinuation { continuation in
        let task = session.downloadTask(with: native) { fetched, answer, error in
          // The fetched file is gone once this returns, so it is moved here.
          continuation.resume(
            with: Result {
              if let error {
                throw error
              }
              guard let fetched, let http = answer as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
              }
              try? FileManager.default.removeItem(at: file)
              try FileManager.default.moveItem(at: fetched, to: file)
              return Response(status: http.statusCode, body: Data())
            }
          )
        }
        flight.hold(task)
        task.resume()
      }
      let took = Date().timeIntervalSince(started)
      log.notice(
        """
        done \(what, privacy: .private(mask: .hash)) status \(response.status) \
        in \(took, format: .fixed(precision: 1)) s
        """
      )
      return response
    } catch {
      log.error("failed \(what, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)")
      throw TransferFailure(
        what: what,
        seconds: Date().timeIntervalSince(started),
        progress: "",
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
    if !request.body.isEmpty {
      native.httpBody = request.body
    }
    return native
  }

  private func response(body: Data, answer: URLResponse) throws -> Response {
    guard let http = answer as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    return Response(
      status: http.statusCode,
      body: body,
      headers: http.allHeaderFields.reduce(into: [String: String]()) { all, pair in
        all["\(pair.key)"] = "\(pair.value)"
      }
    )
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
    String(localized: "\(what) failed after \(Int(seconds.rounded()).formatted()) s")
      + (progress.isEmpty ? "" : ", \(progress)")
      + ": \(cause.localizedDescription)"
  }
}

/// The task of one download, kept so its progress can be asked for.
private final class Flight: Sendable {
  private let tasks = OSAllocatedUnfairLock(initialState: [URLSessionTask]())

  func hold(_ task: URLSessionTask) {
    tasks.withLock { $0.append(task) }
  }

  /// Bytes received so far and bytes expected; zeros before the download has begun.
  func progress() -> (Int64, Int64) {
    tasks.withLock { tasks in
      tasks.first.map { ($0.countOfBytesReceived, $0.countOfBytesExpectedToReceive) } ?? (0, 0)
    }
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
          ? String(
            localized: "Uploading: \(totalBytesSent.formatted(.byteCount(style: .file))) of \(totalBytesExpectedToSend.formatted(.byteCount(style: .file)))"
          )
          : String(localized: "Sent. Waiting for the cloud to confirm")
      )
    }
  }

  func summary() -> String {
    let (sent, total) = counts.withLock { $0 }
    return String(
      localized: "\(sent.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file))) sent"
    )
  }
}
