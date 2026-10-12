import Foundation
import OffloadCore

/// A file in the temporary directory that exists for one test.
struct Scratch {
  let file: URL

  init(_ content: Data) throws {
    file = FileManager.default.temporaryDirectory
      .appendingPathComponent("offload-\(UUID().uuidString).bin")
    try content.write(to: file)
  }

  func remove() {
    try? FileManager.default.removeItem(at: file)
  }
}

/// A network that replays prepared responses and remembers what was asked of it.
actor ScriptedWire: Wire {
  private var script: [Response]
  private var journal: [Request] = []
  private var files: [URL] = []

  init(_ script: [Response]) {
    self.script = script
  }

  func response(to request: Request) async throws -> Response {
    journal.append(request)
    return script.removeFirst()
  }

  func response(to request: Request, sending file: URL) async throws -> Response {
    journal.append(request)
    files.append(file)
    return script.removeFirst()
  }

  func asked() -> [Request] {
    journal
  }

  func sent() -> [URL] {
    files
  }
}

struct Outage: Error {}

/// A refusal that asking again will not change.
struct Ban: Verdict, LocalizedError {
  var errorDescription: String? {
    "banned for good"
  }
}

/// A depot whose doors and shelves a test arranges.
///
/// Each name has a list of answers about its shelf; they are given in turn
/// and the last one is repeated. A name without answers is not held.
actor ArrangedDepot: Depot {
  private var shelves: [String: [[Fingerprint]]]
  private var troubles: [any Error]
  private var smudges: [any Error]
  private var doors: [String] = []
  private var looks: [String] = []
  private var dates: [String] = []

  /// - Parameters:
  ///   - shelves: Answers about what is held, by name.
  ///   - troubles: Errors the next requests for a door fail with, in turn.
  ///   - smudges: Errors the next notings of a date fail with, in turn.
  init(_ shelves: [String: [[Fingerprint]]], troubles: [any Error], smudges: [any Error]) {
    self.shelves = shelves
    self.troubles = troubles
    self.smudges = smudges
  }

  init(_ shelves: [String: [[Fingerprint]]], troubles: [any Error]) {
    self.init(shelves, troubles: troubles, smudges: [])
  }

  init(_ shelves: [String: [[Fingerprint]]]) {
    self.init(shelves, troubles: [], smudges: [])
  }

  func dated(_ name: String, at taken: Date) async throws {
    if !smudges.isEmpty {
      throw smudges.removeFirst()
    }
    dates.append("\(name) \(Int(taken.timeIntervalSince1970))")
  }

  /// Names dates were noted on, each with the date in seconds since 1970.
  func noted() -> [String] {
    dates
  }

  func door(for name: String, bytes: Int64) async throws -> Request {
    if !troubles.isEmpty {
      throw troubles.removeFirst()
    }
    doors.append(name)
    return Request(
      method: "PUT",
      url: URL(string: "https://uploader.example/\(doors.count)")!,
      headers: [:]
    )
  }

  func shelved(_ name: String) async throws -> [Fingerprint] {
    looks.append(name)
    let answers = shelves[name] ?? [[]]
    if answers.count > 1 {
      shelves[name] = Array(answers.dropFirst())
    }
    return answers[0]
  }

  /// Puts something else on a shelf.
  func put(_ held: [Fingerprint], as name: String) {
    shelves[name] = [held]
  }

  /// Names doors were handed out for.
  func opened() -> [String] {
    doors
  }

  /// Names whose shelves were looked at.
  func looked() -> [String] {
    looks
  }
}

/// A transit that only remembers what it was given, until a test says it ended.
actor RecordedTransit: Transit {
  private var flying: Set<String>
  private var journal: [String] = []
  private var recalled: [String] = []

  /// - Parameter flying: Tags already on their way when the test begins.
  init(flying: Set<String>) {
    self.flying = flying
  }

  init() {
    self.init(flying: [])
  }

  func send(_ file: URL, through request: Request, tagged tag: String) async throws {
    journal.append(
      "\(tag) \(file.lastPathComponent) \(request.method) \(request.url.absoluteString)"
    )
    flying.insert(tag)
  }

  func underway() async -> Set<String> {
    flying
  }

  func recall(_ tags: Set<String>) async {
    recalled.append(contentsOf: tags.sorted())
    flying.subtract(tags)
  }

  /// Ends the sending of a file, as the system would.
  func end(_ tag: String) {
    flying.remove(tag)
  }

  /// What was sent, in order: tag, file, method and address.
  func sent() -> [String] {
    journal
  }

  func called() -> [String] {
    recalled
  }
}

/// A depot that keeps everyone asking what it holds waiting until a test lets them through.
actor GatedDepot: Depot {
  private let origin: any Depot
  private var open = false
  private var held: [CheckedContinuation<Void, Never>] = []
  private var watchers: [CheckedContinuation<Void, Never>] = []

  init(_ origin: any Depot) {
    self.origin = origin
  }

  func door(for name: String, bytes: Int64) async throws -> Request {
    try await origin.door(for: name, bytes: bytes)
  }

  func dated(_ name: String, at taken: Date) async throws {
    try await origin.dated(name, at: taken)
  }

  func shelved(_ name: String) async throws -> [Fingerprint] {
    if !open {
      for watcher in watchers {
        watcher.resume()
      }
      watchers = []
      await withCheckedContinuation { held.append($0) }
    }
    return try await origin.shelved(name)
  }

  /// Returns once somebody waits at the gate.
  func reached() async {
    if held.isEmpty {
      await withCheckedContinuation { watchers.append($0) }
    }
  }

  /// Lets everyone through, now and from now on.
  func release() {
    open = true
    for waiting in held {
      waiting.resume()
    }
    held = []
  }
}

/// Remembers what was said, from whatever thread.
final class Notes: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []

  func add(_ line: String) {
    lock.lock()
    lines.append(line)
    lock.unlock()
  }

  func all() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return lines
  }
}
