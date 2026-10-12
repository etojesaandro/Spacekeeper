import Foundation
import OffloadCore
import Testing

@Suite("Sweep of several originals")
struct SweepTests {
  private let hello = Fingerprint(bytes: 5, md5: "5d41402abc4b2a76b9719d911017c592")
  private let wrong = Fingerprint(bytes: 5, md5: "00000000000000000000000000000000")

  /// An original of one file holding "hello".
  private func original(_ label: String, _ scratch: Scratch) -> RecordedOriginal {
    RecordedOriginal(label, [Part(name: "\(label).HEIC", file: scratch.file)])
  }

  @Test("removes all originals in one request once every copy is verified")
  func allMoved() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let bin = RecordedBin(refusing: false)
    let cloud = ScriptedCloud([.success(hello), .success(hello), .success(hello)])

    let fates = await Sweep(
      of: [original("a", scratch), original("b", scratch), original("c", scratch)],
      to: cloud,
      into: bin,
      watched: NoOnlooker()
    ).run()

    #expect(fates == [.moved, .moved, .moved])
    #expect(await bin.asked() == [["a", "b", "c"]])
  }

  @Test("carries on after a failed copy and removes only the verified originals")
  func oneFails() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let bin = RecordedBin(refusing: false)
    let cloud = ScriptedCloud([.success(hello), .success(wrong), .success(hello)])

    let fates = await Sweep(
      of: [original("a", scratch), original("b", scratch), original("c", scratch)],
      to: cloud,
      into: bin,
      watched: NoOnlooker()
    ).run()

    #expect(fates[0] == .moved)
    #expect(fates[2] == .moved)
    guard case .kept(let reason) = fates[1] else {
      Issue.record("the unverified original should have been kept, got \(fates[1])")
      return
    }
    #expect(reason.contains("differs from the original"))
    #expect(await bin.asked() == [["a", "c"]])
  }

  @Test("removes nothing and asks for no removal when no copy is verified")
  func noneVerified() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let bin = RecordedBin(refusing: false)
    let cloud = ScriptedCloud([.failure(Outage()), .success(wrong)])

    let fates = await Sweep(
      of: [original("a", scratch), original("b", scratch)],
      to: cloud,
      into: bin,
      watched: NoOnlooker()
    ).run()

    #expect(fates.allSatisfy { if case .kept = $0 { true } else { false } })
    #expect(await bin.asked().isEmpty)
  }

  @Test("reports verified originals as copied but still present when removal is refused")
  func removalRefused() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let bin = RecordedBin(refusing: true)
    let cloud = ScriptedCloud([.success(hello), .success(hello)])

    let fates = await Sweep(
      of: [original("a", scratch), original("b", scratch)],
      to: cloud,
      into: bin,
      watched: NoOnlooker()
    ).run()

    #expect(fates == [.copied("the user declined"), .copied("the user declined")])
  }

  @Test("lets go of every original after its copy, whether it succeeded or not")
  func releasesAll() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let first = original("a", scratch)
    let second = original("b", scratch)
    let cloud = ScriptedCloud([.success(hello), .failure(Outage())])

    _ = await Sweep(
      of: [first, second],
      to: cloud,
      into: RecordedBin(refusing: false),
      watched: NoOnlooker()
    ).run()

    #expect(await first.released())
    #expect(await second.released())
  }

  @Test("tells the onlooker which original it is copying and how many it removes")
  func narration() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let heard = Heard()
    let cloud = ScriptedCloud([.success(hello), .success(wrong), .success(hello)])

    _ = await Sweep(
      of: [original("a", scratch), original("b", scratch), original("c", scratch)],
      to: cloud,
      into: RecordedBin(refusing: false),
      watched: heard
    ).run()

    #expect(heard.told() == ["copying 1 of 3", "copying 2 of 3", "copying 3 of 3", "discarding 2"])
  }

  @Test("of nothing does nothing")
  func empty() async throws {
    let bin = RecordedBin(refusing: false)

    let fates = await Sweep(
      of: [RecordedOriginal](),
      to: ScriptedCloud([]),
      into: bin,
      watched: NoOnlooker()
    ).run()

    #expect(fates.isEmpty)
    #expect(await bin.asked().isEmpty)
  }
}

/// An onlooker that writes down what it is told, in order.
private final class Heard: Onlooker, @unchecked Sendable {
  private let lock = NSLock()
  private var notes: [String] = []

  func copying(_ number: Int, of count: Int) {
    lock.withLock { notes.append("copying \(number) of \(count)") }
  }

  func discarding(_ count: Int) {
    lock.withLock { notes.append("discarding \(count)") }
  }

  func told() -> [String] {
    lock.withLock { notes }
  }
}
