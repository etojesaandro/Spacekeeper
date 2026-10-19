import Foundation
import SpacekeeperCore
import Testing

@Suite("Kept originals and their return to the photo library")
struct RetrievalTests {
  private let hello = Fingerprint(bytes: 5, md5: "5d41402abc4b2a76b9719d911017c592")
  private let moscow = TimeZone(identifier: "Europe/Moscow")!
  private let stem = "2025/03/2025-03-10_12-47-52_B504FF1B_"

  private func file(_ path: String, made: [Date] = []) -> KeptFile {
    KeptFile(path: path, bytes: 5, print: hello, made: made, preview: [])
  }

  private func originals(_ names: [String]) -> [KeptOriginal] {
    Shelf(folders: [], files: names.map { file($0) }).originals()
  }

  private func through() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("spacekeeper-\(UUID().uuidString)")
  }

  @Test("takes the files that share a moment and an identifier as one original")
  func groups() {
    let kept = originals([
      stem + "IMG_1.MOV",
      "2025/03/2025-03-11_08-00-00_AAAAAAAA_IMG_2.JPG",
      stem + "IMG_1.HEIC",
      "2025/03/notes.txt",
    ])

    #expect(kept.map { $0.name() } == ["IMG_1.HEIC", "IMG_2.JPG", "notes.txt"])
    #expect(kept.map { $0.count() } == [2, 1, 1])
    #expect(kept.map { $0.bytes() } == [10, 5, 5])
    #expect(kept.map { $0.id }.count == Set(kept.map { $0.id }).count)
  }

  @Test("reads the library's name out of an undated file as well")
  func undated() {
    let kept = originals([
      "undated/undated_B504FF1B_IMG_1.JPG", "undated/undated_B504FF1B_IMG_1.MOV",
    ])

    #expect(kept.map { $0.name() } == ["IMG_1.JPG"])
    #expect(kept[0].made(in: moscow).isEmpty)
  }

  @Test("takes a name that only resembles the app's own as a foreign file")
  func lookalikes() {
    let kept = originals([
      "2025-03-10_12-47-52_B504_FF1B_x.JPG",
      "2025-03-10_12-47-52_B504FF1B",
      "2025-03-10.JPG",
    ])

    #expect(
      kept.map { $0.name() }.sorted()
        == ["2025-03-10.JPG", "2025-03-10_12-47-52_B504FF1B", "2025-03-10_12-47-52_B504_FF1B_x.JPG"]
    )
  }

  @Test("tells when an original was made from the cloud's note, else from its name")
  func made() {
    let noted = Date(timeIntervalSince1970: 42)
    let withNote = Shelf(folders: [], files: [file(stem + "IMG_1.JPG", made: [noted])])
      .originals()[0]
    let byName = originals([stem + "IMG_1.JPG"])[0]
    let foreign = originals(["notes.jpg"])[0]

    #expect(withNote.made(in: moscow) == [noted])
    #expect(withNote.noted() == [noted])
    #expect(byName.made(in: moscow) == [Date(timeIntervalSince1970: 1_741_600_072)])
    #expect(byName.noted().isEmpty)
    #expect(foreign.made(in: moscow).isEmpty)
  }

  @Test("hands back a photo as a photo and a video as a video")
  func plain() {
    let photo = originals([stem + "IMG_1.HEIC"])[0]
    let video = originals([stem + "IMG_2.MOV"])[0]

    #expect(photo.parts().map { "\($0.role) \($0.name())" } == ["photo IMG_1.HEIC"])
    #expect(video.parts().map { "\($0.role) \($0.name())" } == ["video IMG_2.MOV"])
    #expect(!photo.video())
    #expect(video.video())
  }

  @Test("hands back a Live Photo as a picture with its moving half")
  func live() {
    let live = originals([stem + "IMG_1.MOV", stem + "IMG_1.HEIC"])[0]

    #expect(
      live.parts().map { "\($0.role) \($0.name())" }
        == ["photo IMG_1.HEIC", "pairedVideo IMG_1.MOV"]
    )
    #expect(live.leading().name().hasSuffix("IMG_1.HEIC"))
    #expect(!live.video())
  }

  @Test("leaves out the result and the recipe of an edit, so the original comes back unedited")
  func edited() {
    let edited = originals([
      stem + "Adjustments.plist",
      stem + "FullSizeRender.jpg",
      stem + "IMG_1.HEIC",
      stem + "IMG_1.AAE",
    ])[0]

    #expect(edited.parts().map { "\($0.role) \($0.name())" } == ["photo IMG_1.HEIC"])
    #expect(edited.count() == 4)
  }

  @Test("hands back RAW beside JPEG as one photo in two formats, the JPEG leading")
  func raw() {
    let pair = originals([stem + "IMG_1.DNG", stem + "IMG_1.JPG"])[0]

    #expect(
      pair.parts().map { "\($0.role) \($0.name())" }
        == ["photo IMG_1.JPG", "alternatePhoto IMG_1.DNG"]
    )
  }

  @Test("has nothing to hand back of a file that is neither photo nor video")
  func foreign() {
    let notes = originals(["notes.txt"])[0]

    #expect(notes.parts().isEmpty)
    #expect(notes.leading().name() == "notes.txt")
    #expect(!notes.video())
  }

  @Test("fetches the files, checks them and hands them to the library with the noted date")
  func restores() async throws {
    let noted = Date(timeIntervalSince1970: 42)
    let shelf = Shelf(
      folders: [],
      files: [file(stem + "IMG_1.HEIC", made: [noted]), file(stem + "IMG_1.MOV", made: [noted])]
    )
    let archive = ArrangedArchive(
      shelves: [:],
      contents: [stem + "IMG_1.HEIC": Data("hello".utf8), stem + "IMG_1.MOV": Data("hello".utf8)]
    )
    let gallery = RecordedGallery(refusing: false)
    let folder = through()

    try await Retrieval(of: shelf.originals()[0], from: archive, into: gallery, through: folder)
      .make()

    #expect(await archive.asked() == [stem + "IMG_1.HEIC", stem + "IMG_1.MOV"])
    #expect(
      await gallery.received() == ["photo IMG_1.HEIC hello", "pairedVideo IMG_1.MOV hello"]
    )
    #expect(await gallery.moments() == [[noted]])
    #expect(!FileManager.default.fileExists(atPath: folder.path))
  }

  @Test("gives the library no date when the cloud has none noted, so the file's own counts")
  func noDate() async throws {
    let archive = ArrangedArchive(shelves: [:], contents: [stem + "IMG_1.JPG": Data("hello".utf8)])
    let gallery = RecordedGallery(refusing: false)

    try await Retrieval(
      of: originals([stem + "IMG_1.JPG"])[0],
      from: archive,
      into: gallery,
      through: through()
    ).make()

    #expect(await gallery.moments() == [[]])
  }

  @Test("hands the library nothing when a download differs from what the cloud keeps")
  func damaged() async throws {
    let archive = ArrangedArchive(shelves: [:], contents: [stem + "IMG_1.JPG": Data("hell".utf8)])
    let gallery = RecordedGallery(refusing: false)
    let folder = through()

    let failure = await #expect(throws: FetchMismatch.self) {
      try await Retrieval(
        of: originals([stem + "IMG_1.JPG"])[0],
        from: archive,
        into: gallery,
        through: folder
      ).make()
    }

    #expect(failure?.localizedDescription.contains("The download of IMG_1.JPG differs") == true)
    #expect(await gallery.received().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
  }

  @Test("hands the library nothing when a file cannot be fetched")
  func unfetched() async throws {
    let archive = ArrangedArchive(shelves: [:], contents: [stem + "IMG_1.HEIC": Data("hello".utf8)])
    let gallery = RecordedGallery(refusing: false)
    let folder = through()

    await #expect(throws: Outage.self) {
      try await Retrieval(
        of: originals([stem + "IMG_1.HEIC", stem + "IMG_1.MOV"])[0],
        from: archive,
        into: gallery,
        through: folder
      ).make()
    }

    #expect(await gallery.received().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: folder.path))
  }

  @Test("fails for a file the library would not take, without fetching it")
  func nothingToRestore() async throws {
    let archive = ArrangedArchive(shelves: [:], contents: [:])

    let failure = await #expect(throws: NothingToRestore.self) {
      try await Retrieval(
        of: originals(["notes.txt"])[0],
        from: archive,
        into: RecordedGallery(refusing: false),
        through: through()
      ).make()
    }

    #expect(
      failure?.localizedDescription.contains("notes.txt is neither a photo nor a video") == true
    )
    #expect(await archive.asked().isEmpty)
  }

  @Test("fails and clears up when the library declines")
  func declined() async throws {
    let archive = ArrangedArchive(shelves: [:], contents: [stem + "IMG_1.JPG": Data("hello".utf8)])
    let folder = through()

    await #expect(throws: Refusal.self) {
      try await Retrieval(
        of: originals([stem + "IMG_1.JPG"])[0],
        from: archive,
        into: RecordedGallery(refusing: true),
        through: folder
      ).make()
    }

    #expect(!FileManager.default.fileExists(atPath: folder.path))
  }

  @Test("an arranged archive shows its shelves and pictures")
  func archiveFake() async throws {
    let shelf = Shelf(folders: ["2025"], files: [])
    let archive = ArrangedArchive(shelves: ["": shelf], contents: [:])

    #expect(try await archive.shelf("") == shelf)
    #expect(try await archive.shelf("x").folders().isEmpty)
    #expect(try await archive.thumbnail(of: file("a.JPG")) == Data("small a.JPG".utf8))
    #expect(try await archive.picture(of: file("a.JPG")) == Data("large a.JPG".utf8))
  }
}
