import Foundation
import SpacekeeperCable
import SpacekeeperCore

// Backs up the photo library of a plugged-in iPhone into a folder.
//
//   spacekeeper-backup [<folder>] [--icloud] [--code <code>]
//
// Open Spacekeeper on the phone, choose "Back up to a computer", and give this
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
guard plain.count <= 1, flags.isSubset(of: ["--icloud", "--code"]) else {
  print("Usage: spacekeeper-backup [<folder>] [--icloud] [--code <code>]")
  print("Without a folder the backup goes into Pictures/iPhone in your home folder.")
  exit(2)
}
let folder = plain.first.map { URL(fileURLWithPath: $0) }
  ?? FileManager.default.homeDirectoryForCurrentUser
  .appendingPathComponent("Pictures")
  .appendingPathComponent("iPhone")
print("Backup folder: \(folder.path)")
// Started by a double click on Windows, the window would vanish with the last words in it.
#if os(Windows)
let linger = CommandLine.arguments.count == 1
#else
let linger = false
#endif

/// Ends the tool, leaving its words on screen until Enter when nobody started it from a console.
func finish(_ status: Int32) -> Never {
  if linger {
    print("Press Enter to close.")
    _ = readLine()
  }
  exit(status)
}

// The phone cannot call the computer, so the tool reaches the phone's hatch through
// the service that carries connections over the cable.
#if os(Windows)
let muxd = Muxd(doorway: LoopbackDoorway(port: 27015, patience: 600))
let missing = """
  Apple's cable service is not running. Install "Apple Devices" from the Microsoft Store
  (or iTunes), plug the iPhone in, unlock it and tap "Trust".
  """
// The service asks the phone for trust only when Apple's own app opens.
let untrusted = """
  The iPhone does not trust this computer yet. With the iPhone plugged in and unlocked,
  open "Apple Devices" (or iTunes). The iPhone asks "Trust This Computer?": tap Trust and
  enter its passcode. Apple Devices can be closed afterwards.
  """
#elseif os(macOS)
let muxd = Muxd(doorway: UnixDoorway(path: "/var/run/usbmuxd", patience: 600))
let missing = "macOS's cable service does not answer. Restart the Mac and try again."
let untrusted = """
  The iPhone does not trust this Mac yet. With the iPhone plugged in and unlocked, open
  Finder and select the iPhone in the sidebar. The iPhone asks "Trust This Computer?":
  tap Trust and enter its passcode.
  """
#else
let muxd = Muxd(doorway: UnixDoorway(path: "/var/run/usbmuxd", patience: 600))
let missing = "usbmuxd is not running. Install it with: sudo apt install usbmuxd"
let untrusted = """
  The iPhone does not trust this computer yet. Unlock the iPhone, unplug it and plug it in
  again, then tap Trust and enter its passcode. If it does not ask, run: idevicepair pair
  """
#endif
let phones: [Phone]
do {
  phones = try muxd.phones()
} catch {
  print(missing)
  print("(\(error.localizedDescription))")
  finish(1)
}
guard let phone = phones.first else {
  print("No iPhone is plugged in. Connect it with a cable, unlock it, and tap \"Trust\" if asked.")
  finish(1)
}
if phones.count > 1 {
  print("Several iPhones are plugged in; using the first one.")
}
// Without trust the phone lets nothing through, and the backup would fail for no clear reason.
if muxd.trust(of: phone) == .missing {
  print(untrusted)
  print("Press Enter once the iPhone trusts this computer.")
  _ = readLine()
  if muxd.trust(of: phone) == .missing {
    print("The iPhone still does not seem to trust this computer; trying anyway.")
  }
}

if code.isEmpty {
  print("Code shown on the iPhone: ", terminator: "")
  code = readLine() ?? ""
}
// The phone shows the code in two groups, and it may be typed that way.
code = code.filter { !$0.isWhitespace }
let reach: Reach = flags.contains("--icloud") ? .everything : .device
// A folder backed up before the app was renamed keeps its record under the old name;
// without it, everything would be fetched again.
let record = folder.appendingPathComponent(".spacekeeper-backup.json")
let earlier = folder.appendingPathComponent(".offload-backup.json")
if !FileManager.default.fileExists(atPath: record.path),
  FileManager.default.fileExists(atPath: earlier.path)
{
  try? FileManager.default.moveItem(at: earlier, to: record)
}
let started = Date()
do {
  let report = try await Backup(
    from: HttpHandset(
      // A file that has to come from iCloud first may keep the phone silent for a while.
      wire: TunnelWire(muxd: muxd, phone: phone, port: 47810),
      root: URL(string: "http://iphone/")!,
      code: code,
      reach: reach
    ),
    into: folder,
    ledger: Ledger(file: record),
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
    print("Stopped early: the phone stopped answering. Is Spacekeeper still open on its backup screen?")
  }
  print("Took \(Int(Date().timeIntervalSince(started))) s. Backup folder: \(folder.path)")
  finish(report.failed.isEmpty && !report.broken ? 0 : 1)
} catch is TunnelRefused where muxd.trust(of: phone) == .missing {
  print(untrusted)
  print("Then run this again.")
  finish(1)
} catch let refused as TunnelRefused where refused.unanswered() {
  print("The iPhone does not answer. Open Spacekeeper, then More, then \"Back up to a computer\",")
  print("keep that screen open, and run this again.")
  finish(1)
} catch {
  print("The backup could not start: \(error.localizedDescription)")
  print("Is Spacekeeper open on \"Back up to a computer\", and is the code right?")
  finish(1)
}
