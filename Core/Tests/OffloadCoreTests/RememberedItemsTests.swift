import Foundation
import OffloadCore
import Testing

@Suite("Remembered library items")
struct RememberedItemsTests {
  private func place() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("offload-\(UUID().uuidString)")
      .appendingPathComponent("items.json")
  }

  private func item(_ id: String, modified: Date) -> MediaItem {
    MediaItem(
      id: id,
      name: "\(id).MOV",
      video: true,
      seconds: 12.5,
      created: Date(timeIntervalSince1970: 1_700_000_000.25),
      modified: modified,
      size: 5_000_000_000,
      local: 1_234
    )
  }

  @Test("come back exactly as they were kept")
  func roundTrip() throws {
    let file = place()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let kept = [
      item("a", modified: Date(timeIntervalSince1970: 1_750_000_000.123456)),
      item("b", modified: Date(timeIntervalSince1970: 1_750_000_001)),
    ]

    try RememberedItems(file: file).keep(kept)
    let back = RememberedItems(file: file).items()

    #expect(back == ["a": kept[0], "b": kept[1]])
  }

  @Test("still match the modification time they were kept with")
  func modificationSurvives() throws {
    let file = place()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let changed = Date(timeIntervalSince1970: 1_750_000_000.123456)

    try RememberedItems(file: file).keep([item("a", modified: changed)])
    let back = RememberedItems(file: file).items()

    #expect(back["a"]?.unchanged(since: changed) == true)
    #expect(back["a"]?.unchanged(since: changed.addingTimeInterval(1)) == false)
  }

  @Test("are replaced, not added to, by the next keeping")
  func replaced() throws {
    let file = place()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let remembered = RememberedItems(file: file)

    try remembered.keep([item("a", modified: .distantPast), item("b", modified: .distantPast)])
    try remembered.keep([item("b", modified: .distantPast)])

    #expect(remembered.items().keys.sorted() == ["b"])
  }

  @Test("are none when nothing was ever kept")
  func nothingKept() {
    #expect(RememberedItems(file: place()).items().isEmpty)
  }

  @Test("are none when the file holds something unreadable")
  func unreadable() throws {
    let file = place()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("not json at all".utf8).write(to: file)

    #expect(RememberedItems(file: file).items().isEmpty)
  }
}
