import Foundation
import OffloadCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Uploads one file to the real Yandex Disk, checks the copy and times it,
// without touching the original.
//
//   YANDEX_DISK_TOKEN=<token> swift run offload-probe <file>
//   YANDEX_DISK_TOKEN=<token> swift run offload-probe <file> plain
//   YANDEX_DISK_TOKEN=<token> swift run offload-probe <file> queued
//
// With "plain" the file travels under its own extension, which shows the
// speed limit the Disk puts on videos, archives and data files. With
// "queued" it goes the way the app sends it: through the outbox, in steps.

guard
  let token = ProcessInfo.processInfo.environment["YANDEX_DISK_TOKEN"],
  (2...3).contains(CommandLine.arguments.count)
else {
  print("Usage: YANDEX_DISK_TOKEN=<token> offload-probe <file> [plain|queued]")
  exit(2)
}
let file = URL(fileURLWithPath: CommandLine.arguments[1])
let stem = "probe-\(Int(Date().timeIntervalSince1970))"
let name = "\(stem)-\(file.lastPathComponent)"
// Uploads here are throttled on purpose, so the wire must outlast a minute of slow sending.
let patient = URLSessionConfiguration.default
patient.timeoutIntervalForRequest = 600
let api = YandexApi(token: token, wire: URLSessionWire(session: URLSession(configuration: patient)))
let disk =
  CommandLine.arguments.last == "plain"
  ? YandexDisk(
    api: api,
    folder: "app:/",
    disguise: Disguise(suffix: "", exempt: []),
    patience: Patience(tries: 60, pause: .seconds(2))
  )
  : YandexDisk(api: api)
if CommandLine.arguments.last == "queued" {
  let desk = FileManager.default.temporaryDirectory
    .appendingPathComponent("offload-probe-\(UUID().uuidString)")
  defer {
    try? FileManager.default.removeItem(at: desk)
  }
  do {
    let store = desk.appendingPathComponent("files")
    try FileManager.default.createDirectory(
      at: store.appendingPathComponent("probe"),
      withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(
      at: file,
      to: store.appendingPathComponent("probe/\(file.lastPathComponent)")
    )
    let facts = try FileManager.default.attributesOfItem(atPath: file.path)
    let size = (facts[.size] as? NSNumber)?.int64Value ?? 0
    let changed = (facts[.modificationDate] as? Date) ?? Date()
    // The file goes into a folder for its year and month, as the app's uploads do.
    let name = Placement(taken: changed, id: stem, zone: .current)
      .path(for: file.lastPathComponent)
    let transit = ImmediateTransit(session: URLSession(configuration: patient))
    let outbox = Outbox(
      manifest: Manifest(file: desk.appendingPathComponent("manifest.json")),
      store: store,
      depot: YandexDisk(api: api),
      transit: transit,
      patience: Patience(tries: 15, pause: .seconds(2)),
      abreast: 8,
      sends: 1,
      say: { print("  \($0)") }
    )
    let started = Date()
    try await outbox.accept(
      try Consignment(
        item: MediaItem(
          id: stem,
          name: name,
          video: false,
          seconds: 0,
          created: Date(),
          modified: Date(),
          size: size,
          local: size
        ),
        stamp: Date(),
        parcels: [
          Parcel(
            name: name,
            file: "probe/\(file.lastPathComponent)",
            bytes: size,
            print: try FingerprintOf(file).value(),
            taken: changed
          ),
        ],
        aim: .copy
      )
    )
    for (tag, status) in await transit.answers() {
      await outbox.landed(tag, status: status)
    }
    let standing = await outbox.consignments().map { $0.standing() }
    print(String(format: "Took:   %.1f s", Date().timeIntervalSince(started)))
    print(standing == [.safe] ? "Safe: app:/\(name)" : "NOT SAFE: \(standing)")
    exit(standing == [.safe] ? 0 : 1)
  } catch {
    print("Failed: \(error)")
    exit(1)
  }
}
do {
  let local = try FingerprintOf(file).value()
  print("Local:  \(local)")
  let started = Date()
  let remote = try await disk.kept(file, as: name)
  let seconds = Date().timeIntervalSince(started)
  let megabytes =
    Double((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?
      .int64Value ?? 0) / 1_000_000
  print("Cloud:  \(remote)")
  print(
    String(format: "Took:   %.1f s, %.2f MB/s", seconds, megabytes / max(seconds, 0.001))
  )
  print(remote == local ? "Match: app:/\(name)" : "MISMATCH: app:/\(name)")
  exit(remote == local ? 0 : 1)
} catch {
  print("Failed: \(error)")
  exit(1)
}

/// A transit that sends each file at once and keeps the answers for the probe to pass on.
actor ImmediateTransit: Transit {
  private let session: URLSession
  private var ended: [(String, Int)] = []

  init(session: URLSession) {
    self.session = session
  }

  func send(_ file: URL, through request: Request, tagged tag: String) async throws {
    var native = URLRequest(url: request.url)
    native.httpMethod = request.method
    let (_, answer) = try await session.upload(for: native, fromFile: file)
    ended.append((tag, (answer as? HTTPURLResponse)?.statusCode ?? 0))
  }

  func underway() async -> Set<String> {
    []
  }

  func recall(_ tags: Set<String>) async {}

  /// Tags of the files sent, each with the HTTP status its upload was answered with.
  func answers() -> [(String, Int)] {
    ended
  }
}
