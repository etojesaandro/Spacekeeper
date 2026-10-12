import Foundation

/// The originals on their way to a cloud, remembered so that the journey
/// survives the app being closed.
///
/// Each file is sent by something that may outlive the app, and what became
/// of it is found out from the cloud itself. So every step can be repeated:
/// after a crash, a relaunch or a lost answer the outbox looks where things
/// stand and goes on from there. A file counts as safe only when the cloud
/// reports the very size and MD5 the file had on the device.
public actor Outbox {
  private let manifest: Manifest
  private let store: URL
  private let depot: any Depot
  private let transit: any Transit
  private let patience: Patience
  private let abreast: Int
  private let sends: Int
  private let say: @Sendable (String) -> Void
  private var busy: Set<String> = []
  private var again: Set<String> = []

  /// - Parameters:
  ///   - manifest: Where the consignments are remembered.
  ///   - store: Folder the waiting files lie in.
  ///   - depot: The cloud the files go to.
  ///   - transit: What sends the files.
  ///   - patience: How long to wait for the cloud to file an arrived file away.
  ///   - abreast: How many files may be on their way at once.
  ///   - sends: How many times one file is sent before giving it up.
  ///   - say: Told what happens, for the log.
  public init(
    manifest: Manifest,
    store: URL,
    depot: any Depot,
    transit: any Transit,
    patience: Patience,
    abreast: Int,
    sends: Int,
    say: @escaping @Sendable (String) -> Void
  ) {
    self.manifest = manifest
    self.store = store
    self.depot = depot
    self.transit = transit
    self.patience = patience
    self.abreast = abreast
    self.sends = sends
    self.say = say
  }

  /// Everything on its way, in the order it was taken in.
  public func consignments() -> [Consignment] {
    manifest.consignments()
  }

  /// Takes in an original whose files lie ready in the store, and starts sending them.
  public func accept(_ consignment: Consignment) async throws {
    try manifest.alter { listed in
      guard !listed.contains(where: { $0.id == consignment.id }) else {
        throw AlreadyUnderway(name: consignment.original().name)
      }
      return listed + [consignment]
    }
    await fill()
  }

  /// Looks where every file stands and moves each as far as it can go right now.
  public func advance() async {
    for name in manifest.consignments().flatMap({ $0.files() }).map({ $0.name }) {
      // A passing trouble, such as no connection, would meet every file alike.
      guard await settle(name) else {
        return
      }
    }
  }

  /// The sending of a file ended with the cloud's answer.
  public func landed(_ name: String, status: Int) async {
    switch status {
    case 201, 202:
      mark(name) { $0.leg == .staged || $0.leg == .sent ? $0.on(.delivered) : $0 }
    case 413:
      mark(name) { $0.on(.failed("Yandex Disk refused it as too large for this account")) }
    case 507:
      mark(name) { $0.on(.failed("Yandex Disk has no room left for it")) }
    default:
      returned(name, reason: "Yandex Disk answered the upload with HTTP \(status)")
    }
    say("\(name): sending ended with HTTP \(status)")
    await settle(name)
    await fill()
  }

  /// The sending of a file broke off.
  public func lost(_ name: String, reason: String) async {
    returned(name, reason: reason)
    say("\(name): sending broke off: \(reason)")
    await fill()
  }

  /// The sending of a file was called off, which is not held against it.
  public func dropped(_ name: String) async {
    mark(name) { $0.leg == .sent ? $0.waiting(after: $0.sends - 1) : $0 }
    say("\(name): sending was called off")
    await fill()
  }

  /// Gives the failed files of these originals a fresh start.
  public func retry(_ ids: Set<String>) async {
    try? manifest.alter { listed in
      listed.map { consignment in
        guard ids.contains(consignment.id) else {
          return consignment
        }
        return consignment.with { parcel in
          if case .failed = parcel.leg {
            return parcel.waiting(after: 0)
          }
          return parcel
        }
      }
    }
    await fill()
  }

  /// Forgets these originals and removes what waits in the store for them.
  ///
  /// It says nothing about the originals themselves, which stay or go as
  /// the caller decides.
  public func clear(_ ids: Set<String>) async {
    let leaving = manifest.consignments().filter { ids.contains($0.id) }.flatMap { $0.files() }
    await transit.recall(Set(leaving.map { $0.name }))
    try? manifest.alter { listed in
      listed.filter { !ids.contains($0.id) }
    }
    for folder in Set(leaving.map { self.folder(of: $0) }) {
      try? FileManager.default.removeItem(at: store.appendingPathComponent(folder))
    }
  }

  /// Removes from the store whatever no consignment refers to.
  ///
  /// It must not run while files are being laid ready for a new consignment.
  public func tidy() {
    let wanted = Set(manifest.consignments().flatMap { $0.files() }.map { folder(of: $0) })
    let lying = (try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []
    for entry in lying where !wanted.contains(entry) {
      try? FileManager.default.removeItem(at: store.appendingPathComponent(entry))
    }
  }

  /// Sends waiting files for as long as there is room on the way.
  private func fill() async {
    for parcel in manifest.consignments().flatMap({ $0.files() }) where parcel.leg == .staged {
      guard room(beside: parcel.name), await settle(parcel.name) else {
        return
      }
    }
  }

  /// Whether one more file may be on its way beside those that are.
  private func room(beside name: String) -> Bool {
    manifest.consignments().flatMap { $0.files() }
      .filter { $0.leg == .sent && $0.name != name }.count < abreast
  }

  /// Works on one file until nothing more can be done for it now.
  ///
  /// - Returns: False when a passing trouble stopped the work.
  @discardableResult
  private func settle(_ name: String) async -> Bool {
    guard busy.insert(name).inserted else {
      // Whoever is at it must look again, as things have changed meanwhile.
      again.insert(name)
      return true
    }
    var smooth = true
    repeat {
      again.remove(name)
      do {
        try await step(name)
        smooth = true
      } catch let verdict as any Verdict where verdict.stands() {
        mark(name) { $0.on(.failed(verdict.localizedDescription)) }
        say("\(name): given up: \(verdict.localizedDescription)")
        smooth = true
      } catch {
        say("\(name): will be tried again: \(error.localizedDescription)")
        smooth = false
      }
    } while again.contains(name)
    busy.remove(name)
    return smooth
  }

  private func step(_ name: String) async throws {
    guard let parcel = listed(name).first else {
      return
    }
    switch parcel.leg {
    case .safe, .failed:
      return
    case .staged:
      guard room(beside: name) else {
        return
      }
      if await transit.underway().contains(name) {
        // It was sent, but the app stopped before noting it.
        mark(name) { $0.on(.sent) }
      } else {
        try await send(parcel)
      }
    case .sent:
      guard await !transit.underway().contains(name) else {
        return
      }
      // The sending ended without word of how, so the cloud is asked.
      if try await depot.shelved(name) == [parcel.print] {
        safe(parcel)
      } else {
        try await send(parcel)
      }
    case .delivered:
      var found: [Fingerprint] = []
      for attempt in 0..<patience.tries {
        if attempt > 0 {
          try await Task.sleep(for: patience.pause)
        }
        found = try await depot.shelved(name)
        if found == [parcel.print] {
          safe(parcel)
          return
        }
      }
      if let other = found.first {
        throw CopyMismatch(name: name, local: parcel.print, remote: other)
      }
      say("\(name): the cloud has taken it but does not show it yet")
    }
  }

  private func send(_ parcel: Parcel) async throws {
    guard parcel.sends < sends else {
      throw Undelivered(name: parcel.name, sends: parcel.sends)
    }
    guard room(beside: parcel.name) else {
      return
    }
    let file = store.appendingPathComponent(parcel.file)
    guard FileManager.default.fileExists(atPath: file.path) else {
      throw StagedFileGone(name: parcel.name)
    }
    let door = try await depot.door(for: parcel.name, bytes: parcel.bytes)
    try await transit.send(file, through: door, tagged: parcel.name)
    mark(parcel.name) { $0.sent() }
    say("\(parcel.name): sending \(parcel.bytes) bytes, time \(parcel.sends + 1)")
  }

  private func safe(_ parcel: Parcel) {
    mark(parcel.name) { $0.on(.safe) }
    try? FileManager.default.removeItem(at: store.appendingPathComponent(parcel.file))
    say("\(parcel.name): the cloud holds an identical copy")
  }

  /// Puts a file whose sending failed back in line, or gives it up after too many sendings.
  private func returned(_ name: String, reason: String) {
    let limit = sends
    mark(name) { parcel in
      guard parcel.leg == .sent || parcel.leg == .staged else {
        return parcel
      }
      return parcel.sends < limit
        ? parcel.waiting(after: parcel.sends)
        : parcel.on(.failed(reason))
    }
  }

  private func listed(_ name: String) -> [Parcel] {
    manifest.consignments().flatMap { $0.files() }.filter { $0.name == name }
  }

  private func mark(_ name: String, _ change: (Parcel) -> Parcel) {
    do {
      try manifest.alter { listed in
        listed.map { $0.with { $0.name == name ? change($0) : $0 } }
      }
    } catch {
      // What could not be noted is found out again from the cloud next time.
      say("\(name): could not be noted: \(error.localizedDescription)")
    }
  }

  /// The folder of the store a file lies in.
  private func folder(of parcel: Parcel) -> String {
    String(parcel.file.prefix { $0 != "/" })
  }
}

/// The cloud holds something other than what was sent.
public struct CopyMismatch: LocalizedError, CustomStringConvertible, Verdict {
  private let name: String
  private let local: Fingerprint
  private let remote: Fingerprint

  init(name: String, local: Fingerprint, remote: Fingerprint) {
    self.name = name
    self.local = local
    self.remote = remote
  }

  public var description: String {
    "Cloud copy of \(name) differs from the original: sent \(local), cloud holds \(remote)"
  }

  public var errorDescription: String? {
    description
  }
}

/// The original is already on its way.
public struct AlreadyUnderway: LocalizedError, CustomStringConvertible {
  private let name: String

  init(name: String) {
    self.name = name
  }

  public var description: String {
    "\(name) is already on its way"
  }

  public var errorDescription: String? {
    description
  }
}

/// A file was sent several times and the cloud never came to hold it.
public struct Undelivered: LocalizedError, CustomStringConvertible, Verdict {
  private let name: String
  private let sends: Int

  init(name: String, sends: Int) {
    self.name = name
    self.sends = sends
  }

  public var description: String {
    "\(name) was sent \(sends) times and did not arrive"
  }

  public var errorDescription: String? {
    description
  }
}

/// The copy that waited to be sent is no longer on the device.
public struct StagedFileGone: LocalizedError, CustomStringConvertible, Verdict {
  private let name: String

  init(name: String) {
    self.name = name
  }

  public var description: String {
    "The copy of \(name) prepared for upload is gone from this device"
  }

  public var errorDescription: String? {
    description
  }
}
