import Foundation
import SpacekeeperCore

/// A file in the temporary directory that exists for one test.
struct Scratch {
  let file: URL

  init(_ content: Data) throws {
    file = FileManager.default.temporaryDirectory
      .appendingPathComponent("spacekeeper-\(UUID().uuidString).bin")
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

  func response(to request: Request, saving file: URL) async throws -> Response {
    journal.append(request)
    let answer = script.removeFirst()
    try answer.body.write(to: file)
    return Response(status: answer.status, body: Data())
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

/// An archive whose files a test lays out, each with the content a fetch brings back.
actor ArrangedArchive: Archive {
  private let shelves: [String: Shelf]
  private let contents: [String: Data]
  private var fetches: [String] = []

  /// - Parameters:
  ///   - shelves: What each folder holds, by path.
  ///   - contents: What fetching each file brings back, by path.
  init(shelves: [String: Shelf], contents: [String: Data]) {
    self.shelves = shelves
    self.contents = contents
  }

  func shelf(_ path: String) async throws -> Shelf {
    shelves[path] ?? Shelf(folders: [], files: [])
  }

  func thumbnail(of file: KeptFile) async throws -> Data {
    Data("small \(file.id)".utf8)
  }

  func picture(of file: KeptFile) async throws -> Data {
    Data("large \(file.id)".utf8)
  }

  func fetched(_ file: KeptFile, into place: URL) async throws {
    fetches.append(file.id)
    guard let content = contents[file.id] else {
      throw Outage()
    }
    try content.write(to: place)
  }

  /// Paths of the files fetched, in order.
  func asked() -> [String] {
    fetches
  }
}

/// A gallery that remembers what it was handed and what the files held at that moment.
actor RecordedGallery: Gallery {
  private let refusing: Bool
  private var taken: [String] = []
  private var dates: [[Date]] = []

  init(refusing: Bool) {
    self.refusing = refusing
  }

  func take(_ parts: [FetchedPart], made: [Date]) async throws {
    for part in parts {
      let content = (try? Data(contentsOf: part.file)).map { String(decoding: $0, as: UTF8.self) }
      taken.append("\(part.role) \(part.name) \(content ?? "missing")")
    }
    dates.append(made)
    if refusing {
      throw Refusal()
    }
  }

  /// What was handed over: the part each file plays, its name and its content.
  func received() -> [String] {
    taken
  }

  func moments() -> [[Date]] {
    dates
  }
}

struct Refusal: LocalizedError {
  var errorDescription: String? {
    "the library declined"
  }
}

/// A phone's stock a test lays out: items, and what each of their files holds.
actor ArrangedStock: Stock {
  private let listed: [MediaItem]
  private let contents: [String: [Data]]
  private let places: [String: [String]]
  private let cut: Set<String>
  private var holding: [String] = []
  private var fetches: [String] = []

  /// - Parameters:
  ///   - items: The items of the library.
  ///   - contents: What each file of an item holds, by item identifier.
  ///   - places: Paths offered for an item's files, where a test wants other than the usual.
  ///   - cut: Identifiers of items whose files break off after their first bytes.
  init(
    items: [MediaItem],
    contents: [String: [Data]],
    places: [String: [String]],
    cut: Set<String>
  ) {
    self.listed = items
    self.contents = contents
    self.places = places
    self.cut = cut
  }

  init(items: [MediaItem], contents: [String: [Data]]) {
    self.init(items: items, contents: contents, places: [:], cut: [])
  }

  func items() async -> [MediaItem] {
    listed
  }

  func pieces(of id: String) async throws -> [Piece] {
    guard let files = contents[id] else {
      throw Outage()
    }
    return files.indices.map { index in
      Piece(
        index: index,
        path: places[id]?[index] ?? "2025/03/\(id)-\(index).bin",
        taken: Date(timeIntervalSince1970: 1_741_600_072)
      )
    }
  }

  func pour(_ index: Int, of id: String, fetching: Bool, into sink: any Sink) async throws {
    fetches.append("\(id) \(index) \(fetching)")
    guard let files = contents[id], files.indices.contains(index) else {
      throw Outage()
    }
    let content = files[index]
    try await sink.take(content.prefix(content.count / 2))
    if cut.contains(id) {
      throw Outage()
    }
    try await sink.take(content.dropFirst(content.count / 2))
  }

  func held(_ ids: [String]) async {
    holding += ids
  }

  /// Identifiers a computer said it holds.
  func told() -> [String] {
    holding
  }

  /// What was poured: item, file number and whether iCloud was to be asked.
  func poured() -> [String] {
    fetches
  }
}

/// A network that leads straight into a hatch, as a cable would.
struct HatchWire: Wire {
  private let hatch: Hatch

  init(_ hatch: Hatch) {
    self.hatch = hatch
  }

  func response(to request: Request) async throws -> Response {
    let pile = Pile()
    var head = "\(request.method) \(request.url.path)"
    if let query = request.url.query(percentEncoded: true) {
      head += "?\(query)"
    }
    head += " HTTP/1.1\r\n"
    for (name, value) in request.headers {
      head += "\(name): \(value)\r\n"
    }
    await hatch.serve(Data((head + "\r\n").utf8), through: pile)
    let raw = await pile.all()
    guard let gap = raw.range(of: Data("\r\n\r\n".utf8)) else {
      throw Outage()
    }
    let status = String(decoding: raw[..<gap.lowerBound], as: UTF8.self)
      .split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
    return Response(status: status, body: Data(raw[gap.upperBound...]))
  }

  func response(to request: Request, sending file: URL) async throws -> Response {
    throw Outage()
  }

  func response(to request: Request, saving file: URL) async throws -> Response {
    let answer = try await response(to: request)
    try answer.body.write(to: file)
    return Response(status: answer.status, body: Data())
  }
}

/// A sink that piles up what it is given.
actor Pile: Sink {
  private var data = Data()

  func take(_ chunk: Data) async throws {
    data.append(chunk)
  }

  func all() -> Data {
    data
  }
}

/// A backup onlooker that writes down what it is told.
final class BackupNotes: BackupOnlooker, @unchecked Sendable {
  private let notes = Notes()

  func copying(_ number: Int, of count: Int, _ item: MediaItem) {
    notes.add("copying \(number) of \(count): \(item.name)")
  }

  func failed(_ item: MediaItem, _ reason: String) {
    notes.add("failed \(item.name)")
  }

  func all() -> [String] {
    notes.all()
  }
}
