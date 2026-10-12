import Foundation
import OffloadCore
import Testing

@Suite("Offload of one original")
struct OffloadTests {
  private let hello = Fingerprint(bytes: 5, md5: "5d41402abc4b2a76b9719d911017c592")
  private let world = Fingerprint(bytes: 5, md5: "7d793037a0760186574b0282f2f435e7")

  @Test("removes the original once the cloud holds an identical copy")
  func removesVerified() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let original = RecordedOriginal([Part(name: "IMG_0001.HEIC", file: scratch.file)])
    let cloud = ScriptedCloud([.success(hello)])

    try await Offload(of: original, to: cloud).run()

    #expect(await original.removed())
  }

  @Test("uploads every file of an original under its own name before removing it")
  func uploadsEveryPart() async throws {
    let picture = try Scratch(Data("hello".utf8))
    let clip = try Scratch(Data("world".utf8))
    defer {
      picture.remove()
      clip.remove()
    }
    let original = RecordedOriginal([
      Part(name: "IMG_0001.HEIC", file: picture.file),
      Part(name: "IMG_0001.MOV", file: clip.file),
    ])
    let cloud = ScriptedCloud([.success(hello), .success(world)])

    try await Offload(of: original, to: cloud).run()

    #expect(await cloud.received() == ["IMG_0001.HEIC", "IMG_0001.MOV"])
    #expect(await original.removed())
  }

  @Test("keeps the original when a later file of it fails to verify")
  func keepsOnLaterMismatch() async throws {
    let picture = try Scratch(Data("hello".utf8))
    let clip = try Scratch(Data("world".utf8))
    defer {
      picture.remove()
      clip.remove()
    }
    let original = RecordedOriginal([
      Part(name: "IMG_0001.HEIC", file: picture.file),
      Part(name: "IMG_0001.MOV", file: clip.file),
    ])
    let cloud = ScriptedCloud([.success(hello), .success(hello)])

    await #expect(throws: CopyMismatch.self) {
      try await Offload(of: original, to: cloud).run()
    }

    #expect(await original.removed() == false)
  }

  @Test("keeps the original when the cloud copy has different content")
  func keepsOnDifferentContent() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let original = RecordedOriginal([Part(name: "IMG_0001.HEIC", file: scratch.file)])
    let cloud = ScriptedCloud([
      .success(Fingerprint(bytes: 5, md5: "00000000000000000000000000000000")),
    ])

    await #expect(throws: CopyMismatch.self) {
      try await Offload(of: original, to: cloud).run()
    }

    #expect(await original.removed() == false)
  }

  @Test("keeps the original when the cloud copy is shorter")
  func keepsOnTruncatedCopy() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let original = RecordedOriginal([Part(name: "IMG_0001.HEIC", file: scratch.file)])
    let cloud = ScriptedCloud([
      .success(Fingerprint(bytes: 4, md5: "5d41402abc4b2a76b9719d911017c592")),
    ])

    await #expect(throws: CopyMismatch.self) {
      try await Offload(of: original, to: cloud).run()
    }

    #expect(await original.removed() == false)
  }

  @Test("keeps the original when the upload fails")
  func keepsOnFailedUpload() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let original = RecordedOriginal([Part(name: "IMG_0001.HEIC", file: scratch.file)])
    let cloud = ScriptedCloud([.failure(Outage())])

    await #expect(throws: Outage.self) {
      try await Offload(of: original, to: cloud).run()
    }

    #expect(await original.removed() == false)
  }

  @Test("keeps an original that offers no files, as nothing would back it up")
  func keepsWithoutParts() async throws {
    let original = RecordedOriginal([])
    let cloud = ScriptedCloud([])

    await #expect(throws: NothingToOffload.self) {
      try await Offload(of: original, to: cloud).run()
    }

    #expect(await original.removed() == false)
    #expect(await cloud.received().isEmpty)
  }
}
