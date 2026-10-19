import Foundation
import SpacekeeperCore
import os

/// The system's own uploading, which goes on while the app is suspended or closed.
///
/// The session must be a background one. It copies each file as the upload
/// starts, without taking more space, so the file may go once its upload
/// has been answered.
struct SystemTransit: Transit {
  private let session: URLSession

  /// - Parameter session: A background session; its delegate hears how uploads end.
  init(session: URLSession) {
    self.session = session
  }

  func send(_ file: URL, through request: Request, tagged tag: String) async throws {
    var native = URLRequest(url: request.url)
    native.httpMethod = request.method
    for (name, value) in request.headers {
      native.setValue(value, forHTTPHeaderField: name)
    }
    let task = session.uploadTask(with: native, fromFile: file)
    task.taskDescription = tag
    task.resume()
  }

  func underway() async -> Set<String> {
    Set(
      await session.allTasks
        .filter { $0.state == .running || $0.state == .suspended }
        .compactMap { $0.taskDescription }
    )
  }

  func recall(_ tags: Set<String>) async {
    for task in await session.allTasks where tags.contains(task.taskDescription ?? "") {
      task.cancel()
    }
  }
}

/// What the system tells about the uploads it carries out.
enum TransitNews: Sendable {
  /// This many bytes of the file with the tag have gone.
  case moved(String, Int64)

  /// The upload of the file with the tag was answered with this HTTP status.
  case landed(String, Int)

  /// The upload of the file with the tag broke off, for the reason given.
  case lost(String, String)

  /// The upload of the file with the tag was called off.
  case dropped(String)

  /// The system has told everything that happened while the app was away.
  case quiet
}

/// Hears what the system says about the uploads and passes it on as news.
///
/// URLSession reports through a delegate object, on a thread of its own.
final class TransitEars: NSObject, URLSessionTaskDelegate, Sendable {
  private let news: AsyncStream<TransitNews>.Continuation
  private let log = Logger(subsystem: "Spacekeeper", category: "transit")
  private let percents = OSAllocatedUnfairLock(initialState: [String: Int64]())

  /// - Parameter news: Where the news goes.
  init(news: AsyncStream<TransitNews>.Continuation) {
    self.news = news
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    guard let tag = task.taskDescription else {
      return
    }
    // Told once per whole percent, as URLSession reports every few kilobytes.
    let percent = totalBytesSent * 100 / max(totalBytesExpectedToSend, 1)
    let moved = percents.withLock { percents in
      let before = percents[tag] ?? -1
      percents[tag] = percent
      return before != percent
    }
    if moved {
      if percent % 10 == 0 {
        log.notice(
          "\(tag, privacy: .private(mask: .hash)): sent \(totalBytesSent) of \(totalBytesExpectedToSend) bytes"
        )
      }
      news.yield(.moved(tag, totalBytesSent))
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    guard let tag = task.taskDescription else {
      return
    }
    percents.withLock { percents in
      percents[tag] = nil
    }
    if let error {
      log.error("\(tag, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)")
      news.yield(
        (error as NSError).code == NSURLErrorCancelled
          ? .dropped(tag)
          : .lost(tag, error.localizedDescription)
      )
    } else if let answer = task.response as? HTTPURLResponse {
      log.notice("\(tag, privacy: .private(mask: .hash)): answered with HTTP \(answer.statusCode)")
      news.yield(.landed(tag, answer.statusCode))
    } else {
      news.yield(.lost(tag, String(localized: "The cloud gave no answer")))
    }
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    log.notice("the system has told everything")
    news.yield(.quiet)
  }
}
