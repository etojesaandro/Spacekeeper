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
//
// With "plain" the file travels under its own extension, which shows the
// speed limit the Disk puts on videos, archives and data files.

guard
  let token = ProcessInfo.processInfo.environment["YANDEX_DISK_TOKEN"],
  (2...3).contains(CommandLine.arguments.count)
else {
  print("Usage: YANDEX_DISK_TOKEN=<token> offload-probe <file> [plain]")
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
    disguise: "",
    patience: Patience(tries: 60, pause: .seconds(2))
  )
  : YandexDisk(api: api)
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
