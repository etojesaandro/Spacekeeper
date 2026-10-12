import Foundation
import OffloadCore
import Testing

@Suite("Fingerprint of a local file")
struct FingerprintOfTests {
  @Test("matches the known MD5 and length of a small file")
  func smallFile() throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }

    let fingerprint = try FingerprintOf(scratch.file).value()

    #expect(fingerprint == Fingerprint(bytes: 5, md5: "5d41402abc4b2a76b9719d911017c592"))
  }

  @Test("of an empty file is the MD5 of nothing with zero length")
  func emptyFile() throws {
    let scratch = try Scratch(Data())
    defer { scratch.remove() }

    let fingerprint = try FingerprintOf(scratch.file).value()

    #expect(fingerprint == Fingerprint(bytes: 0, md5: "d41d8cd98f00b204e9800998ecf8427e"))
  }

  @Test("does not depend on how the file is cut into chunks")
  func chunking() throws {
    let scratch = try Scratch(Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
    defer { scratch.remove() }

    let whole = try FingerprintOf(scratch.file, chunk: 1 << 20).value()
    let pieces = try FingerprintOf(scratch.file, chunk: 7).value()

    #expect(whole == pieces)
  }

  @Test("differs when a single byte of the content differs")
  func differentContent() throws {
    let first = try Scratch(Data("hello".utf8))
    let second = try Scratch(Data("hellp".utf8))
    defer {
      first.remove()
      second.remove()
    }

    let left = try FingerprintOf(first.file).value()
    let right = try FingerprintOf(second.file).value()

    #expect(left != right)
  }

  @Test("ignores the letter case of the MD5 text")
  func letterCase() {
    let lower = Fingerprint(bytes: 5, md5: "5d41402abc4b2a76b9719d911017c592")
    let upper = Fingerprint(bytes: 5, md5: "5D41402ABC4B2A76B9719D911017C592")

    #expect(lower == upper)
  }

  @Test("fails for a file that does not exist")
  func missingFile() {
    let nowhere = FileManager.default.temporaryDirectory
      .appendingPathComponent("offload-missing-\(UUID().uuidString)")

    #expect(throws: UnreadableFile.self) {
      try FingerprintOf(nowhere).value()
    }
  }
}
