import Foundation
import OffloadCore
import Testing

@Suite("Outbox of originals on their way to a cloud")
struct OutboxTests {
  private let hello = Fingerprint(bytes: 5, md5: "5d41402abc4b2a76b9719d911017c592")
  private let other = Fingerprint(bytes: 5, md5: "00000000000000000000000000000000")

  /// A place on disk that exists for one test, with files laid ready to send.
  private struct Desk {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("offload-\(UUID().uuidString)")

    var store: URL {
      root.appendingPathComponent("files")
    }

    var manifest: Manifest {
      Manifest(file: root.appendingPathComponent("manifest.json"))
    }

    /// Lays a file ready and returns the parcel for it.
    func parcel(_ name: String, in folder: String) throws -> Parcel {
      let place = store.appendingPathComponent(folder)
      try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
      try Data("hello".utf8).write(to: place.appendingPathComponent(name))
      return Parcel(
        name: name,
        file: "\(folder)/\(name)",
        bytes: 5,
        print: Fingerprint(bytes: 5, md5: "5d41402abc4b2a76b9719d911017c592")
      )
    }

    func consignment(_ id: String, _ names: [String]) throws -> Consignment {
      try Consignment(
        item: MediaItem(
          id: id,
          name: names[0],
          video: true,
          seconds: 1,
          created: Date(timeIntervalSince1970: 1),
          modified: Date(timeIntervalSince1970: 2),
          size: Int64(5 * names.count),
          local: Int64(5 * names.count)
        ),
        stamp: Date(timeIntervalSince1970: 2),
        parcels: try names.map { try parcel($0, in: "folder-\(id)") }
      )
    }

    func lying(_ path: String) -> Bool {
      FileManager.default.fileExists(atPath: store.appendingPathComponent(path).path)
    }

    func remove() {
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func outbox(
    _ desk: Desk,
    _ depot: any Depot,
    _ transit: RecordedTransit,
    abreast: Int = 8,
    sends: Int = 3,
    tries: Int = 1
  ) -> Outbox {
    Outbox(
      manifest: desk.manifest,
      store: desk.store,
      depot: depot,
      transit: transit,
      patience: Patience(tries: tries, pause: .zero),
      abreast: abreast,
      sends: sends,
      say: { _ in }
    )
  }

  @Test("sends an accepted file through the door the cloud opens for it")
  func sends() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let depot = ArrangedDepot([:])
    let transit = RecordedTransit()
    let outbox = outbox(desk, depot, transit)

    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))

    #expect(await transit.sent() == ["A.MOV A.MOV PUT https://uploader.example/1"])
    #expect(await outbox.consignments().map { $0.standing() } == [.travelling])
  }

  @Test("counts a file as safe once the cloud reports the very same content")
  func safe() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(desk, ArrangedDepot(["A.MOV": [[hello]]]), transit)
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))

    await transit.end("A.MOV")
    await outbox.landed("A.MOV", status: 201)

    #expect(await outbox.consignments().map { $0.standing() } == [.safe])
    #expect(!desk.lying("folder-a/A.MOV"))
  }

  @Test("never counts a file as safe when the cloud holds different content")
  func mismatch() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(desk, ArrangedDepot(["A.MOV": [[other]]]), transit)
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))

    await transit.end("A.MOV")
    await outbox.landed("A.MOV", status: 201)

    let standing = await outbox.consignments()[0].standing()
    guard case .failed(let reason) = standing else {
      Issue.record("expected a failure, got \(standing)")
      return
    }
    #expect(reason.contains("differs from the original"))
    #expect(desk.lying("folder-a/A.MOV"))
  }

  @Test("never counts a file as safe on the cloud's word that it took the upload")
  func deliveredIsNotSafe() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let depot = ArrangedDepot([:])
    let transit = RecordedTransit()
    let outbox = outbox(desk, depot, transit)
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))

    await transit.end("A.MOV")
    await outbox.landed("A.MOV", status: 202)

    #expect(await outbox.consignments().map { $0.standing() } == [.travelling])
    #expect(await transit.sent().count == 1)
    #expect(desk.lying("folder-a/A.MOV"))
  }

  @Test("finds a slowly filed file safe on a later look")
  func laterLook() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let depot = ArrangedDepot([:])
    let transit = RecordedTransit()
    let outbox = outbox(desk, depot, transit)
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))
    await transit.end("A.MOV")
    await outbox.landed("A.MOV", status: 202)

    await depot.put([hello], as: "A.MOV")
    await outbox.advance()

    #expect(await outbox.consignments().map { $0.standing() } == [.safe])
  }

  @Test("waits a while for the cloud to file an arrived file away")
  func patience() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(desk, ArrangedDepot(["A.MOV": [[], [], [hello]]]), transit, tries: 3)
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))

    await transit.end("A.MOV")
    await outbox.landed("A.MOV", status: 201)

    #expect(await outbox.consignments().map { $0.standing() } == [.safe])
  }

  @Test("keeps an original travelling until every one of its files is safe")
  func everyFile() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(
      desk,
      ArrangedDepot(["A.HEIC": [[hello]], "A.MOV": [[hello]]]),
      transit
    )
    try await outbox.accept(try desk.consignment("a", ["A.HEIC", "A.MOV"]))

    await transit.end("A.HEIC")
    await outbox.landed("A.HEIC", status: 201)
    let halfway = await outbox.consignments()[0].standing()
    await transit.end("A.MOV")
    await outbox.landed("A.MOV", status: 201)

    #expect(halfway == .travelling)
    #expect(await outbox.consignments().map { $0.standing() } == [.safe])
  }

  @Test("sends a file again when the cloud answers the upload with a failure")
  func resendsAfterRefusal() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(desk, ArrangedDepot([:]), transit)
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))

    await transit.end("A.MOV")
    await outbox.landed("A.MOV", status: 500)

    #expect(await transit.sent().count == 2)
    #expect(await outbox.consignments().map { $0.standing() } == [.travelling])
  }

  @Test("gives a file up after sending it as often as allowed")
  func givesUp() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(desk, ArrangedDepot([:]), transit, sends: 2)
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))

    await transit.end("A.MOV")
    await outbox.lost("A.MOV", reason: "the connection was lost")
    await transit.end("A.MOV")
    await outbox.lost("A.MOV", reason: "the connection was lost")

    #expect(await transit.sent().count == 2)
    #expect(
      await outbox.consignments().map { $0.standing() } == [.failed("the connection was lost")]
    )
  }

  @Test(
    "gives a file up at once when the cloud says it will never fit",
    arguments: [413, 507]
  )
  func neverFits(status: Int) async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(desk, ArrangedDepot([:]), transit)
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))

    await transit.end("A.MOV")
    await outbox.landed("A.MOV", status: status)

    let standing = await outbox.consignments()[0].standing()
    #expect(await transit.sent().count == 1)
    #expect(standing != .travelling && standing != .safe)
  }

  @Test("does not hold a called-off sending against the file")
  func calledOff() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(desk, ArrangedDepot([:]), transit, sends: 2)
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))

    for _ in 0..<5 {
      await transit.end("A.MOV")
      await outbox.dropped("A.MOV")
    }

    #expect(await transit.sent().count == 6)
    #expect(await outbox.consignments().map { $0.standing() } == [.travelling])
  }

  @Test("after a relaunch finds safe a file that arrived while the app was gone")
  func arrivedMeanwhile() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let before = RecordedTransit()
    try await outbox(desk, ArrangedDepot([:]), before)
      .accept(try desk.consignment("a", ["A.MOV"]))
    let after = RecordedTransit()

    await outbox(desk, ArrangedDepot(["A.MOV": [[hello]]]), after).advance()

    #expect(await after.sent().isEmpty)
    #expect(
      await outbox(desk, ArrangedDepot([:]), after).consignments().map { $0.standing() }
        == [.safe]
    )
  }

  @Test("after a relaunch sends again a file whose sending vanished")
  func vanished() async throws {
    let desk = Desk()
    defer { desk.remove() }
    try await outbox(desk, ArrangedDepot([:]), RecordedTransit())
      .accept(try desk.consignment("a", ["A.MOV"]))
    let after = RecordedTransit()

    await outbox(desk, ArrangedDepot([:]), after).advance()

    #expect(await after.sent().count == 1)
  }

  @Test("after a relaunch leaves alone a file that is still being sent")
  func stillFlying() async throws {
    let desk = Desk()
    defer { desk.remove() }
    try await outbox(desk, ArrangedDepot([:]), RecordedTransit())
      .accept(try desk.consignment("a", ["A.MOV"]))
    let depot = ArrangedDepot([:])
    let after = RecordedTransit(flying: ["A.MOV"])

    await outbox(desk, depot, after).advance()

    #expect(await after.sent().isEmpty)
    #expect(await depot.looked().isEmpty)
    #expect(await depot.opened().isEmpty)
  }

  @Test("does not send twice a file that was sent just before the app stopped")
  func sentUnnoted() async throws {
    let desk = Desk()
    defer { desk.remove() }
    // Nothing gets sent with no room on the way, so the file stays noted as waiting.
    try await outbox(desk, ArrangedDepot([:]), RecordedTransit(), abreast: 0)
      .accept(try desk.consignment("a", ["A.MOV"]))
    let after = RecordedTransit(flying: ["A.MOV"])
    let outbox = outbox(desk, ArrangedDepot(["A.MOV": [[hello]]]), after)

    await outbox.advance()
    await after.end("A.MOV")
    await outbox.landed("A.MOV", status: 201)

    #expect(await after.sent().isEmpty)
    #expect(await outbox.consignments().map { $0.standing() } == [.safe])
  }

  @Test("keeps no more files on their way at once than allowed")
  func abreast() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(
      desk,
      ArrangedDepot(["A.MOV": [[hello]], "B.MOV": [[hello]]]),
      transit,
      abreast: 1
    )
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))
    try await outbox.accept(try desk.consignment("b", ["B.MOV"]))
    await outbox.advance()
    let first = await transit.sent().count

    await transit.end("A.MOV")
    await outbox.landed("A.MOV", status: 201)

    #expect(first == 1)
    #expect(await transit.sent().map { $0.prefix(5) } == ["A.MOV", "B.MOV"])
  }

  @Test("gives a file up when the cloud refuses it for good")
  func verdict() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(desk, ArrangedDepot([:], troubles: [Ban()]), transit)

    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))

    #expect(await transit.sent().isEmpty)
    #expect(await outbox.consignments().map { $0.standing() } == [.failed("banned for good")])
  }

  @Test("tries again later after a passing trouble, such as no connection")
  func passingTrouble() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(desk, ArrangedDepot([:], troubles: [Outage()]), transit)
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))
    let stalled = await transit.sent().count

    await outbox.advance()

    #expect(stalled == 0)
    #expect(await transit.sent().count == 1)
    #expect(await outbox.consignments().map { $0.standing() } == [.travelling])
  }

  @Test("stops at a passing trouble rather than meet it again with every file")
  func stopsAtTrouble() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let depot = ArrangedDepot([:], troubles: [Outage(), Outage()])
    let transit = RecordedTransit()
    let outbox = outbox(desk, depot, transit)

    try await outbox.accept(try desk.consignment("a", ["A.HEIC", "A.MOV"]))
    await outbox.advance()
    await outbox.advance()

    #expect(await transit.sent().count == 2)
  }

  @Test("takes a server failure as passing and a refusal of the token as final")
  func realRefusals() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let wire = ScriptedWire([
      Response(status: 503, body: Data()),
      Response(status: 401, body: Data(#"{"error":"UnauthorizedError"}"#.utf8)),
    ])
    let disk = YandexDisk(token: "t0ken", wire: wire)
    let outbox = outbox(desk, disk, RecordedTransit())

    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))
    let first = await outbox.consignments()[0].standing()
    await outbox.advance()
    let second = await outbox.consignments()[0].standing()

    #expect(first == .travelling)
    #expect(second != .travelling && second != .safe)
  }

  @Test("gives a file up when its waiting copy is gone from the device")
  func copyGone() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let consignment = try desk.consignment("a", ["A.MOV"])
    try FileManager.default.removeItem(at: desk.store.appendingPathComponent("folder-a/A.MOV"))
    let outbox = outbox(desk, ArrangedDepot([:]), RecordedTransit())

    try await outbox.accept(consignment)

    let standing = await outbox.consignments()[0].standing()
    #expect(standing != .travelling && standing != .safe)
  }

  @Test("refuses an original that is already on its way")
  func twice() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let outbox = outbox(desk, ArrangedDepot([:]), RecordedTransit())
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))

    let failure = await #expect(throws: AlreadyUnderway.self) {
      try await outbox.accept(try desk.consignment("a", ["A.MOV"]))
    }

    #expect(failure?.localizedDescription == "A.MOV is already on its way")
    #expect(await outbox.consignments().count == 1)
  }

  @Test("sends a given-up file again when asked to retry")
  func retry() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(desk, ArrangedDepot([:], troubles: [Ban()]), transit)
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))

    await outbox.retry(["a"])

    #expect(await transit.sent().count == 1)
    #expect(await outbox.consignments().map { $0.standing() } == [.travelling])
  }

  @Test("forgets a cleared original, calls off its sending and removes its waiting files")
  func clear() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(desk, ArrangedDepot([:]), transit)
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))
    try await outbox.accept(try desk.consignment("b", ["B.MOV"]))

    await outbox.clear(["a"])

    #expect(await outbox.consignments().map { $0.id } == ["b"])
    #expect(await transit.called() == ["A.MOV"])
    #expect(!desk.lying("folder-a"))
    #expect(desk.lying("folder-b/B.MOV"))
  }

  @Test("ignores word about a file it no longer knows")
  func strangers() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(desk, ArrangedDepot([:]), transit)

    await outbox.landed("X.MOV", status: 201)
    await outbox.lost("X.MOV", reason: "gone")
    await outbox.dropped("X.MOV")

    #expect(await outbox.consignments().isEmpty)
    #expect(await transit.sent().isEmpty)
  }

  @Test("tidies away what no original refers to and keeps the rest")
  func tidy() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let outbox = outbox(desk, ArrangedDepot([:]), RecordedTransit())
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))
    _ = try desk.parcel("stray.bin", in: "folder-stray")

    await outbox.tidy()

    #expect(desk.lying("folder-a/A.MOV"))
    #expect(!desk.lying("folder-stray"))
  }

  @Test("keeps a safe original safe when word of its upload comes late")
  func lateWord() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(desk, ArrangedDepot(["A.MOV": [[hello]]]), transit)
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))
    await transit.end("A.MOV")
    await outbox.advance()

    await outbox.landed("A.MOV", status: 201)
    await outbox.lost("A.MOV", reason: "late")
    await outbox.dropped("A.MOV")

    #expect(await transit.sent().count == 1)
    #expect(await outbox.consignments().map { $0.standing() } == [.safe])
  }

  @Test("gives up a file that keeps vanishing on the way")
  func keepsVanishing() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(desk, ArrangedDepot([:]), transit, sends: 1)
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))

    await transit.end("A.MOV")
    await outbox.advance()

    #expect(await transit.sent().count == 1)
    #expect(
      await outbox.consignments().map { $0.standing() }
        == [.failed("A.MOV was sent 1 times and did not arrive")]
    )
  }

  @Test("waits for room on the way before sending a vanished file again")
  func vanishedWaitsForRoom() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let before = outbox(desk, ArrangedDepot([:]), RecordedTransit())
    try await before.accept(try desk.consignment("a", ["A.MOV"]))
    try await before.accept(try desk.consignment("b", ["B.MOV"]))
    let after = RecordedTransit(flying: ["A.MOV"])

    await outbox(desk, ArrangedDepot([:]), after, abreast: 1).advance()

    #expect(await after.sent().isEmpty)
  }

  @Test("retries only the failed files of the originals named")
  func retryNamed() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(desk, ArrangedDepot([:], troubles: [Ban(), Ban()]), transit)
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))
    try await outbox.accept(try desk.consignment("b", ["B.MOV"]))
    try await outbox.accept(try desk.consignment("c", ["C.MOV"]))

    await outbox.retry(["a", "c"])

    #expect(await transit.sent().map { $0.prefix(5) } == ["C.MOV", "A.MOV"])
    #expect(
      await outbox.consignments().map { $0.standing() }
        == [.travelling, .failed("banned for good"), .travelling]
    )
  }

  @Test("looks again when word arrives while it is busy with the same file")
  func wordWhileBusy() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let depot = GatedDepot(ArrangedDepot(["A.MOV": [[], [hello]]]))
    let transit = RecordedTransit()
    let outbox = outbox(desk, depot, transit)
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))
    await transit.end("A.MOV")

    async let first: Void = outbox.landed("A.MOV", status: 201)
    await depot.reached()
    await outbox.advance()
    await depot.release()
    await first

    #expect(await outbox.consignments().map { $0.standing() } == [.safe])
  }

  @Test("finds out again from the cloud what it could not note down")
  func cannotNote() async throws {
    let desk = Desk()
    let files = FileManager.default
    defer {
      try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: desk.root.path)
      desk.remove()
    }
    let notes = Notes()
    let transit = RecordedTransit()
    let outbox = Outbox(
      manifest: desk.manifest,
      store: desk.store,
      depot: ArrangedDepot(["A.MOV": [[hello]]]),
      transit: transit,
      patience: Patience(tries: 1, pause: .zero),
      abreast: 8,
      sends: 3,
      say: { notes.add($0) }
    )
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))
    await transit.end("A.MOV")

    try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: desk.root.path)
    await outbox.landed("A.MOV", status: 201)
    let stuck = await outbox.consignments()[0].standing()
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: desk.root.path)
    await outbox.advance()

    #expect(stuck == .travelling)
    #expect(notes.all().contains { $0.contains("could not be noted") })
    #expect(await outbox.consignments().map { $0.standing() } == [.safe])
  }

  @Test("tidies nothing when there is no store yet")
  func tidyNothing() async throws {
    let desk = Desk()
    defer { desk.remove() }

    await outbox(desk, ArrangedDepot([:]), RecordedTransit()).tidy()

    #expect(!desk.lying(""))
  }

  @Test("counts as gone what was reported of a file being sent, and all of an arrived one")
  func progress() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let transit = RecordedTransit()
    let outbox = outbox(desk, ArrangedDepot(["A.MOV": [[], [hello]]]), transit)
    try await outbox.accept(try desk.consignment("a", ["A.MOV"]))

    let flying = await outbox.consignments()[0]
    await transit.end("A.MOV")
    await outbox.landed("A.MOV", status: 201)
    let arrived = await outbox.consignments()[0].gone(sent: [:])
    await outbox.advance()
    let safe = await outbox.consignments()[0].gone(sent: [:])

    #expect(flying.gone(sent: [:]) == 0)
    #expect(flying.gone(sent: ["A.MOV": 3]) == 3)
    #expect(flying.gone(sent: ["A.MOV": 99]) == 5)
    #expect(flying.gone(sent: ["A.MOV": -1]) == 0)
    #expect(arrived == 5)
    #expect(safe == 5)
  }
}

@Suite("Consignment")
struct ConsignmentTests {
  private let hello = Fingerprint(bytes: 5, md5: "5d41402abc4b2a76b9719d911017c592")

  private func item() -> MediaItem {
    MediaItem(
      id: "a",
      name: "A.MOV",
      video: true,
      seconds: 1,
      created: Date(timeIntervalSince1970: 1),
      modified: Date(timeIntervalSince1970: 2),
      size: 30,
      local: 30
    )
  }

  @Test("cannot be made of no files, as nothing would back the original up")
  func empty() {
    let failure = #expect(throws: NothingToOffload.self) {
      try Consignment(item: item(), stamp: Date(timeIntervalSince1970: 2), parcels: [])
    }

    #expect(failure?.localizedDescription.contains("no files to upload") == true)
  }

  @Test("weighs as much as its files together")
  func bytes() throws {
    let consignment = try Consignment(
      item: item(),
      stamp: Date(timeIntervalSince1970: 2),
      parcels: [
        Parcel(name: "A.HEIC", file: "f/A.HEIC", bytes: 10, print: hello),
        Parcel(name: "A.MOV", file: "f/A.MOV", bytes: 20, print: hello),
      ]
    )

    #expect(consignment.bytes() == 30)
    #expect(consignment.original() == item())
  }

  @Test("counts nothing as gone for a file that only waits, whatever is reported")
  func waitingProgress() throws {
    let consignment = try Consignment(
      item: item(),
      stamp: Date(timeIntervalSince1970: 2),
      parcels: [Parcel(name: "A.MOV", file: "f/A.MOV", bytes: 20, print: hello)]
    )

    #expect(consignment.gone(sent: ["A.MOV": 15]) == 0)
  }

  @Test("knows whether the library changed the item after its files were taken")
  func unchanged() throws {
    let consignment = try Consignment(
      item: item(),
      stamp: Date(timeIntervalSince1970: 2),
      parcels: [Parcel(name: "A.MOV", file: "f/A.MOV", bytes: 20, print: hello)]
    )

    #expect(consignment.unchanged(since: Date(timeIntervalSince1970: 2)))
    #expect(!consignment.unchanged(since: Date(timeIntervalSince1970: 3)))
  }
}

@Suite("Manifest of consignments")
struct ManifestTests {
  @Test("lists nothing when its file is missing or unreadable")
  func unreadable() throws {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("offload-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }

    let missing = Manifest(file: file).consignments()
    try Data("not json".utf8).write(to: file)
    let broken = Manifest(file: file).consignments()

    #expect(missing.isEmpty)
    #expect(broken.isEmpty)
  }

  @Test("leaves the list as it was when a change fails")
  func failedChange() throws {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("offload-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    try Manifest(file: file).alter { $0 }

    #expect(throws: Outage.self) {
      try Manifest(file: file).alter { _ in throw Outage() }
    }

    #expect(Manifest(file: file).consignments().isEmpty)
    #expect(FileManager.default.fileExists(atPath: file.path))
  }
}
