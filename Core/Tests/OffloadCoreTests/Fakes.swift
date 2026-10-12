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

/// A cloud that answers each upload with the next prepared outcome and remembers the names.
actor ScriptedCloud: Cloud {
  private var outcomes: [Result<Fingerprint, Outage>]
  private var names: [String] = []

  init(_ outcomes: [Result<Fingerprint, Outage>]) {
    self.outcomes = outcomes
  }

  func kept(_ file: URL, as name: String) async throws -> Fingerprint {
    names.append(name)
    return try outcomes.removeFirst().get()
  }

  func received() -> [String] {
    names
  }
}

struct Outage: Error {}

/// An original made of scratch files that records whether it was let go of.
actor RecordedOriginal: Original {
  nonisolated let label: String
  private let files: [Part]
  private var gone = false

  init(_ label: String, _ files: [Part]) {
    self.label = label
    self.files = files
  }

  func parts() async throws -> [Part] {
    files
  }

  func release() async {
    gone = true
  }

  func released() -> Bool {
    gone
  }
}

/// A bin that remembers what it was asked to remove, and can be told to refuse.
actor RecordedBin: Bin {
  private let refusing: Bool
  private var requests: [[String]] = []

  init(refusing: Bool) {
    self.refusing = refusing
  }

  func discard(_ items: [RecordedOriginal]) async throws {
    requests.append(items.map { $0.label })
    if refusing {
      throw Refusal()
    }
  }

  func asked() -> [[String]] {
    requests
  }
}

struct Refusal: LocalizedError {
  var errorDescription: String? {
    "the user declined"
  }
}

/// An onlooker that pays no attention.
struct NoOnlooker: Onlooker {
  func copying(_ number: Int, of count: Int) {}

  func discarding(_ count: Int) {}
}
