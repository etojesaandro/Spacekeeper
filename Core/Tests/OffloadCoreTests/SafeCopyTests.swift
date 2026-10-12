import Foundation
import OffloadCore
import Testing

@Suite("Safe copy of one original")
struct SafeCopyTests {
  private let hello = Fingerprint(bytes: 5, md5: "5d41402abc4b2a76b9719d911017c592")
  private let world = Fingerprint(bytes: 5, md5: "7d793037a0760186574b0282f2f435e7")

  @Test("is made when the cloud holds an identical copy")
  func verified() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let original = RecordedOriginal("a", [Part(name: "IMG_0001.HEIC", file: scratch.file)])
    let cloud = ScriptedCloud([.success(hello)])

    try await SafeCopy(of: original, in: cloud).make()

    #expect(await cloud.received() == ["IMG_0001.HEIC"])
  }

  @Test("uploads every file of an original under its own name")
  func everyPart() async throws {
    let picture = try Scratch(Data("hello".utf8))
    let clip = try Scratch(Data("world".utf8))
    defer {
      picture.remove()
      clip.remove()
    }
    let original = RecordedOriginal(
      "a",
      [
        Part(name: "IMG_0001.HEIC", file: picture.file),
        Part(name: "IMG_0001.MOV", file: clip.file),
      ]
    )
    let cloud = ScriptedCloud([.success(hello), .success(world)])

    try await SafeCopy(of: original, in: cloud).make()

    #expect(await cloud.received() == ["IMG_0001.HEIC", "IMG_0001.MOV"])
  }

  @Test("fails when a later file of the original does not verify")
  func laterMismatch() async throws {
    let picture = try Scratch(Data("hello".utf8))
    let clip = try Scratch(Data("world".utf8))
    defer {
      picture.remove()
      clip.remove()
    }
    let original = RecordedOriginal(
      "a",
      [
        Part(name: "IMG_0001.HEIC", file: picture.file),
        Part(name: "IMG_0001.MOV", file: clip.file),
      ]
    )
    let cloud = ScriptedCloud([.success(hello), .success(hello)])

    await #expect(throws: CopyMismatch.self) {
      try await SafeCopy(of: original, in: cloud).make()
    }
  }

  @Test("fails when the cloud copy has different content")
  func differentContent() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let original = RecordedOriginal("a", [Part(name: "IMG_0001.HEIC", file: scratch.file)])
    let cloud = ScriptedCloud([
      .success(Fingerprint(bytes: 5, md5: "00000000000000000000000000000000")),
    ])

    await #expect(throws: CopyMismatch.self) {
      try await SafeCopy(of: original, in: cloud).make()
    }
  }

  @Test("fails when the cloud copy is shorter")
  func truncatedCopy() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let original = RecordedOriginal("a", [Part(name: "IMG_0001.HEIC", file: scratch.file)])
    let cloud = ScriptedCloud([
      .success(Fingerprint(bytes: 4, md5: "5d41402abc4b2a76b9719d911017c592")),
    ])

    await #expect(throws: CopyMismatch.self) {
      try await SafeCopy(of: original, in: cloud).make()
    }
  }

  @Test("fails when the upload fails")
  func failedUpload() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let original = RecordedOriginal("a", [Part(name: "IMG_0001.HEIC", file: scratch.file)])
    let cloud = ScriptedCloud([.failure(Outage())])

    await #expect(throws: Outage.self) {
      try await SafeCopy(of: original, in: cloud).make()
    }
  }

  @Test("fails for an original that offers no files, as nothing would back it up")
  func noParts() async throws {
    let original = RecordedOriginal("a", [])
    let cloud = ScriptedCloud([])

    await #expect(throws: NothingToOffload.self) {
      try await SafeCopy(of: original, in: cloud).make()
    }

    #expect(await cloud.received().isEmpty)
  }
}
