import Foundation
import OffloadCore

// Uploads one file to the real Yandex Disk and checks the copy, without touching the original.
//
//   YANDEX_DISK_TOKEN=<token> swift run offload-probe <file>

guard
  let token = ProcessInfo.processInfo.environment["YANDEX_DISK_TOKEN"],
  CommandLine.arguments.count == 2
else {
  print("Usage: YANDEX_DISK_TOKEN=<token> offload-probe <file>")
  exit(2)
}
let file = URL(fileURLWithPath: CommandLine.arguments[1])
let name = "probe-\(Int(Date().timeIntervalSince1970))-\(file.lastPathComponent)"
do {
  let local = try FingerprintOf(file).value()
  print("Local:  \(local)")
  let remote = try await YandexDisk(token: token).kept(file, as: name)
  print("Cloud:  \(remote)")
  print(remote == local ? "Match: app:/\(name)" : "MISMATCH: app:/\(name)")
  exit(remote == local ? 0 : 1)
} catch {
  print("Failed: \(error)")
  exit(1)
}
