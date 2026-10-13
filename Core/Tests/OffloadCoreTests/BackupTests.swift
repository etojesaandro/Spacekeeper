import Foundation
import OffloadCore
import Testing

@Suite("Backup of the phone's library to a computer")
struct BackupTests {
  private func item(_ id: String, local: Int64 = 5, modified: Double = 2) -> MediaItem {
    let size: Int64 = 5
    return MediaItem(
      id: id,
      name: "\(id).JPG",
      video: false,
      seconds: 0,
      created: Date(timeIntervalSince1970: 1),
      modified: Date(timeIntervalSince1970: modified),
      size: size,
      local: local
    )
  }

  /// A folder on disk that exists for one test.
  private struct Desk {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("offload-\(UUID().uuidString)")

    var ledger: Ledger {
      Ledger(file: folder.appendingPathComponent(".offload-backup.json"))
    }

    func text(_ path: String) -> String {
      (try? String(contentsOf: folder.appendingPathComponent(path), encoding: .utf8)) ?? "missing"
    }

    func files() -> [String] {
      let all = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
        .allObjects as? [URL] ?? []
      return all.filter { !$0.hasDirectoryPath && !$0.lastPathComponent.hasPrefix(".") }
        .map { String($0.path.dropFirst(folder.path.count + 1)) }.sorted()
    }

    func remove() {
      try? FileManager.default.removeItem(at: folder)
    }
  }

  private func handset(
    _ stock: ArrangedStock,
    reach: Reach = .device,
    code: String = "123456"
  ) -> HttpHandset {
    HttpHandset(
      wire: HatchWire(Hatch(stock: stock, code: "123456")),
      root: URL(string: "http://127.0.0.1:47811/")!,
      code: code,
      reach: reach
    )
  }

  private func backup(
    _ desk: Desk,
    _ stock: ArrangedStock,
    reach: Reach = .device,
    notes: BackupNotes = BackupNotes(),
    giveUp: Int = 5
  ) -> Backup {
    Backup(
      from: handset(stock, reach: reach),
      into: desk.folder,
      ledger: desk.ledger,
      reach: reach,
      watched: notes,
      giveUp: giveUp
    )
  }

  @Test("puts every file where the phone says, dated when the original was made")
  func copies() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let stock = ArrangedStock(
      items: [item("a"), item("b")],
      contents: ["a": [Data("hello".utf8), Data("clip!".utf8)], "b": [Data("world".utf8)]]
    )
    let notes = BackupNotes()

    let report = try await backup(desk, stock, notes: notes).run()

    #expect(desk.files() == ["2025/03/a-0.bin", "2025/03/a-1.bin", "2025/03/b-0.bin"])
    #expect(desk.text("2025/03/a-1.bin") == "clip!")
    #expect(report.copied.map { $0.id } == ["a", "b"])
    #expect(report.present == 0 && report.away == 0 && report.failed.isEmpty && !report.broken)
    #expect(notes.all() == ["copying 1 of 2: a.JPG", "copying 2 of 2: b.JPG"])
    let dated = try FileManager.default
      .attributesOfItem(atPath: desk.folder.appendingPathComponent("2025/03/b-0.bin").path)
    #expect(dated[.modificationDate] as? Date == Date(timeIntervalSince1970: 1_741_600_072))
  }

  @Test("tells the phone which items the computer holds")
  func tells() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let stock = ArrangedStock(
      items: [item("a"), item("b")],
      contents: ["a": [Data("hello".utf8)], "b": [Data("world".utf8)]]
    )

    _ = try await backup(desk, stock).run()

    #expect(await stock.told() == ["a", "b"])
  }

  @Test("fetches nothing again that the folder already holds, and still tells the phone of it")
  func again() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let stock = ArrangedStock(items: [item("a")], contents: ["a": [Data("hello".utf8)]])
    _ = try await backup(desk, stock).run()

    let report = try await backup(desk, stock).run()

    #expect(report.copied.isEmpty)
    #expect(report.present == 1)
    #expect(await stock.poured() == ["a 0 false"])
    #expect(await stock.told() == ["a", "a"])
  }

  @Test("fetches again an item the phone has changed, and one whose file went missing")
  func refetches() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let before = ArrangedStock(
      items: [item("a"), item("b")],
      contents: ["a": [Data("hello".utf8)], "b": [Data("world".utf8)]]
    )
    _ = try await backup(desk, before).run()
    try FileManager.default.removeItem(at: desk.folder.appendingPathComponent("2025/03/b-0.bin"))
    let after = ArrangedStock(
      items: [item("a", modified: 3), item("b")],
      contents: ["a": [Data("HELLO".utf8)], "b": [Data("world".utf8)]]
    )

    let report = try await backup(desk, after).run()

    #expect(report.copied.map { $0.id } == ["a", "b"])
    #expect(desk.text("2025/03/a-0.bin") == "HELLO")
    #expect(desk.text("2025/03/b-0.bin") == "world")
  }

  @Test("leaves out what is only in iCloud unless asked to reach for it")
  func icloud() async throws {
    let near = Desk()
    let far = Desk()
    defer {
      near.remove()
      far.remove()
    }
    let items = [item("a"), item("b", local: 0)]
    let contents = ["a": [Data("hello".utf8)], "b": [Data("world".utf8)]]
    let first = ArrangedStock(items: items, contents: contents)
    let second = ArrangedStock(items: items, contents: contents)

    let skipped = try await backup(near, first).run()
    let reached = try await backup(far, second, reach: .everything).run()

    #expect(skipped.copied.map { $0.id } == ["a"])
    #expect(skipped.away == 1)
    #expect(await first.told() == ["a"])
    #expect(reached.copied.map { $0.id } == ["a", "b"])
    #expect(reached.away == 0)
    #expect(await second.poured() == ["a 0 true", "b 0 true"])
  }

  @Test("never takes a file that broke off on the way for a finished copy")
  func brokenOff() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let stock = ArrangedStock(
      items: [item("a"), item("b")],
      contents: [
        "a": [Data(repeating: 7, count: 100)],
        "b": [Data("world".utf8)],
      ],
      places: [:],
      cut: ["a"]
    )
    let notes = BackupNotes()

    let report = try await backup(desk, stock, notes: notes).run()

    #expect(desk.files() == ["2025/03/b-0.bin"])
    #expect(report.copied.map { $0.id } == ["b"])
    #expect(report.failed.count == 1)
    #expect(report.failed[0].hasPrefix("a.JPG: The download of 2025/03/a-0.bin differs"))
    #expect(notes.all().contains("failed a.JPG"))
    #expect(await stock.told() == ["b"])
    #expect(desk.ledger.entries().keys.sorted() == ["b"])
  }

  @Test("fails an item the phone can pour nothing of")
  func nothingPoured() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let stock = ArrangedStock(items: [item("a")], contents: ["a": []])

    let report = try await backup(desk, stock).run()

    #expect(report.failed.count == 1)
    #expect(desk.files().isEmpty)
  }

  @Test(
    "refuses a place outside the backup folder",
    arguments: ["../outside.bin", "/etc/outside.bin", "2025/../../outside.bin", "2025//x.bin"]
  )
  func outside(path: String) async throws {
    let desk = Desk()
    defer { desk.remove() }
    let stock = ArrangedStock(
      items: [item("a")],
      contents: ["a": [Data("hello".utf8)]],
      places: ["a": [path]],
      cut: []
    )

    let report = try await backup(desk, stock).run()

    #expect(report.failed.count == 1)
    #expect(report.failed[0].contains("outside the backup folder"))
    #expect(desk.files().isEmpty)
    #expect(await stock.poured().isEmpty)
  }

  @Test("stops when the phone stops answering, keeps what it has, and tells the phone nothing")
  func gone() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let stock = ArrangedStock(
      items: [item("a"), item("b"), item("c"), item("d")],
      contents: ["a": [Data("hello".utf8)]]
    )

    let report = try await backup(desk, stock, giveUp: 2).run()

    #expect(report.broken)
    #expect(report.copied.map { $0.id } == ["a"])
    #expect(report.failed.count == 2)
    #expect(await stock.told().isEmpty)
    #expect(desk.ledger.entries().keys.sorted() == ["a"])
  }

  @Test("fails as a whole when the phone does not show its library")
  func wrongCode() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let stock = ArrangedStock(items: [item("a")], contents: ["a": [Data("hello".utf8)]])
    let backup = Backup(
      from: handset(stock, code: "000000"),
      into: desk.folder,
      ledger: desk.ledger,
      reach: .device,
      watched: BackupNotes(),
      giveUp: 5
    )

    let failure = await #expect(throws: HatchRefusal.self) {
      try await backup.run()
    }

    #expect(
      failure?.localizedDescription.contains("HTTP 403: The code is wrong or missing") == true
    )
  }

  @Test("keeps its ledger as it goes, so an interrupted run is not lost")
  func keepsLedger() async throws {
    let desk = Desk()
    defer { desk.remove() }
    let items = (0..<21).map { item("i\($0)") }
    let stock = ArrangedStock(
      items: items,
      contents: Dictionary(uniqueKeysWithValues: items.map { ($0.id, [Data("hello".utf8)]) })
    )

    _ = try await backup(desk, stock).run()

    #expect(desk.ledger.entries().count == 21)
    #expect(Ledger(file: desk.folder.appendingPathComponent("none.json")).entries().isEmpty)
  }
}

@Suite("Hatch into the phone's library")
struct HatchTests {
  private func item(_ id: String) -> MediaItem {
    MediaItem(
      id: id,
      name: "\(id).JPG",
      video: false,
      seconds: 0,
      created: Date(timeIntervalSince1970: 1),
      modified: Date(timeIntervalSince1970: 2),
      size: 5,
      local: 5
    )
  }

  private func answer(_ head: String, stock: ArrangedStock) async -> String {
    let pile = Pile()
    await Hatch(stock: stock, code: "123456").serve(Data(head.utf8), through: pile)
    return String(decoding: await pile.all(), as: UTF8.self)
  }

  private var stock: ArrangedStock {
    ArrangedStock(items: [item("a/L0/001")], contents: ["a/L0/001": [Data("hello".utf8)]])
  }

  @Test("answers nothing without the code the phone shows")
  func code() async {
    let none = await answer("GET /items HTTP/1.1\r\n\r\n", stock: stock)
    let wrong = await answer("GET /items HTTP/1.1\r\nX-Offload-Code: 1\r\n\r\n", stock: stock)

    #expect(none.hasPrefix("HTTP/1.1 403 "))
    #expect(wrong.hasPrefix("HTTP/1.1 403 "))
    #expect(!none.contains("a/L0/001"))
  }

  @Test("sends a file followed by the MD5 of what it sent")
  func content() async {
    let sent = await answer(
      "GET /content?id=a/L0/001&index=0 HTTP/1.1\r\nx-offload-code: 123456\r\n\r\n",
      stock: stock
    )

    #expect(sent.hasPrefix("HTTP/1.1 200 OK\r\n"))
    #expect(sent.hasSuffix("\r\n\r\nhello5d41402abc4b2a76b9719d911017c592"))
  }

  @Test("says so when it cannot begin a file, and knows no other requests")
  func refusals() async {
    let missing = await answer(
      "GET /content?id=nope&index=0 HTTP/1.1\r\nX-Offload-Code: 123456\r\n\r\n",
      stock: stock
    )
    let pieces = await answer(
      "GET /pieces?id=nope HTTP/1.1\r\nX-Offload-Code: 123456\r\n\r\n",
      stock: stock
    )
    let unknown = await answer(
      "GET /secrets HTTP/1.1\r\nX-Offload-Code: 123456\r\n\r\n",
      stock: stock
    )
    let garbage = await answer("\r\n\r\n", stock: stock)

    #expect(missing.hasPrefix("HTTP/1.1 500 "))
    #expect(pieces.hasPrefix("HTTP/1.1 500 "))
    #expect(unknown.hasPrefix("HTTP/1.1 404 "))
    #expect(garbage.hasPrefix("HTTP/1.1 403 "))
  }

  @Test("notes what a computer says it holds")
  func held() async {
    let stock = stock

    let noted = await answer(
      "POST /held?id=a/L0/001&id=b HTTP/1.1\r\nX-Offload-Code: 123456\r\n\r\n",
      stock: stock
    )

    #expect(noted.hasPrefix("HTTP/1.1 200 OK"))
    #expect(await stock.told() == ["a/L0/001", "b"])
  }

  @Test("carries identifiers with slashes and plus signs through unharmed")
  func identifiers() async throws {
    let stock = ArrangedStock(
      items: [item("a+b/L0 1")],
      contents: ["a+b/L0 1": [Data("hello".utf8)]]
    )
    let handset = HttpHandset(
      wire: HatchWire(Hatch(stock: stock, code: "123456")),
      root: URL(string: "http://127.0.0.1:47811/")!,
      code: "123456",
      reach: .device
    )

    let items = try await handset.items()
    let pieces = try await handset.pieces(of: items[0])
    try await handset.told(holding: items)

    #expect(pieces.count == 1)
    #expect(await stock.told() == ["a+b/L0 1"])
  }

  @Test("tells the phone of many items in several requests")
  func batches() async throws {
    let wire = ScriptedWire((0..<3).map { _ in Response(status: 200, body: Data()) })
    let handset = HttpHandset(
      wire: wire,
      root: URL(string: "http://127.0.0.1:47811/")!,
      code: "123456",
      reach: .device
    )

    try await handset.told(holding: (0..<120).map { item("i\($0)") })

    let asked = await wire.asked()
    #expect(asked.count == 3)
    #expect(asked.allSatisfy { $0.method == "POST" && $0.headers["X-Offload-Code"] == "123456" })
  }

  @Test("fails on a file too short to carry its MD5, and on a refusal")
  func short() async throws {
    let scratch = try Scratch(Data())
    defer { scratch.remove() }
    let piece = Piece(index: 0, path: "2025/03/a.bin", taken: Date(timeIntervalSince1970: 1))
    func handset(_ answer: Response) -> HttpHandset {
      HttpHandset(
        wire: ScriptedWire([answer]),
        root: URL(string: "http://127.0.0.1:47811/")!,
        code: "123456",
        reach: .device
      )
    }

    let short = await #expect(throws: CutShort.self) {
      try await handset(Response(status: 200, body: Data("tiny".utf8)))
        .fetched(piece, of: item("a"), into: scratch.file)
    }
    let refused = await #expect(throws: HatchRefusal.self) {
      try await handset(Response(status: 500, body: Data("no such item".utf8)))
        .fetched(piece, of: item("a"), into: scratch.file)
    }

    #expect(short?.localizedDescription == "2025/03/a.bin arrived cut short")
    #expect(refused?.localizedDescription.contains("HTTP 500: no such item") == true)
  }
}
