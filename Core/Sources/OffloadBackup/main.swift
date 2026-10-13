import Foundation
import OffloadCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Backs up the photo library of a plugged-in iPhone into a folder.
//
//   swift run offload-backup <folder> [--icloud] [--code <code>]
//
// Open Offload on the phone, choose "Back up to a computer", and give this
// tool the code the phone shows. Running it again fetches only what is new.
// With --icloud the phone also fetches from iCloud what it does not hold.

/// Prints how a backup is getting on, one line per item.
struct Console: BackupOnlooker {
  func copying(_ number: Int, of count: Int, _ item: MediaItem) {
    let size = ByteCountFormatter.string(fromByteCount: item.bytes(), countStyle: .file)
    print("[\(number)/\(count)] \(item.name), \(size)")
  }

  func failed(_ item: MediaItem, _ reason: String) {
    print("    not copied: \(reason)")
  }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let flags = Set(arguments.filter { $0.hasPrefix("--") })
var plain: [String] = []
var code = ""
var skip = false
for (index, argument) in arguments.enumerated() {
  if skip {
    skip = false
  } else if argument == "--code", index + 1 < arguments.count {
    code = arguments[index + 1]
    skip = true
  } else if !argument.hasPrefix("--") {
    plain.append(argument)
  }
}
guard plain.count == 1, flags.isSubset(of: ["--icloud", "--code"]) else {
  print("Usage: offload-backup <folder> [--icloud] [--code <code>]")
  exit(2)
}
let folder = URL(fileURLWithPath: plain[0])

// The phone cannot call the computer over the cable, so a local port is led to its hatch.
let tunnel = Process()
tunnel.executableURL = URL(fileURLWithPath: "/usr/bin/env")
tunnel.arguments = ["iproxy", "47811:47810"]
tunnel.standardOutput = FileHandle.nullDevice
tunnel.standardError = FileHandle.nullDevice
do {
  try tunnel.run()
} catch {
  print("Cannot start iproxy: \(error.localizedDescription)")
  exit(1)
}
defer {
  tunnel.terminate()
}
try await Task.sleep(for: .milliseconds(700))
guard tunnel.isRunning else {
  print("iproxy is needed to reach the phone over the cable and did not start.")
  print("Install it with: sudo apt install libusbmuxd-tools")
  exit(1)
}

if code.isEmpty {
  print("Code shown on the iPhone: ", terminator: "")
  code = readLine() ?? ""
}
// The phone shows the code in two groups, and it may be typed that way.
code = code.filter { !$0.isWhitespace }
// A file that has to come from iCloud first may keep the phone silent for a while.
let patient = URLSessionConfiguration.default
patient.timeoutIntervalForRequest = 600
let reach: Reach = flags.contains("--icloud") ? .everything : .device
let started = Date()
do {
  let report = try await Backup(
    from: HttpHandset(
      wire: URLSessionWire(session: URLSession(configuration: patient)),
      root: URL(string: "http://127.0.0.1:47811/")!,
      code: code,
      reach: reach
    ),
    into: folder,
    ledger: Ledger(file: folder.appendingPathComponent(".offload-backup.json")),
    reach: reach,
    watched: Console(),
    giveUp: 5
  ).run()
  let size = ByteCountFormatter.string(
    fromByteCount: report.copied.reduce(0) { $0 + $1.bytes() },
    countStyle: .file
  )
  print("")
  print("Copied:          \(report.copied.count) items, \(size)")
  print("Already here:    \(report.present)")
  if report.away > 0 {
    print("Only in iCloud:  \(report.away) left out; add --icloud to fetch them")
  }
  if !report.failed.isEmpty {
    print("Not copied:      \(report.failed.count)")
    for line in report.failed.prefix(20) {
      print("  \(line)")
    }
  }
  if report.broken {
    print("Stopped early: the phone stopped answering. Is Offload still open on its backup screen?")
  }
  print("Took \(Int(Date().timeIntervalSince(started))) s. Backup folder: \(folder.path)")
  tunnel.terminate()
  exit(report.failed.isEmpty && !report.broken ? 0 : 1)
} catch {
  print("The backup could not start: \(error.localizedDescription)")
  print("Is Offload open on \"Back up to a computer\", and is the code right?")
  tunnel.terminate()
  exit(1)
}
