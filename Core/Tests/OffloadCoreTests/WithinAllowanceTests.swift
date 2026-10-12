import Foundation
import OffloadCore
import Testing

@Suite("Within the Yandex Disk allowance")
struct WithinAllowanceTests {
  private let hello = Fingerprint(bytes: 5, md5: "5d41402abc4b2a76b9719d911017c592")

  private func limits(largest: Int, total: Int, used: Int) -> Response {
    Response(
      status: 200,
      body: Data(
        #"{"max_file_size":\#(largest),"total_space":\#(total),"used_space":\#(used)}"#.utf8
      )
    )
  }

  @Test("uploads a file that fits both the file limit and the free space")
  func fits() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let wire = ScriptedWire([limits(largest: 100, total: 1000, used: 10)])
    let inner = ScriptedCloud([.success(hello)])

    let kept = try await WithinAllowance(inner, api: YandexApi(token: "t0ken", wire: wire))
      .kept(scratch.file, as: "IMG_0001.HEIC")

    #expect(kept == hello)
    #expect(await inner.received() == ["IMG_0001.HEIC"])
  }

  @Test("asks the Disk for its limits with the user's token")
  func asksLimits() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let wire = ScriptedWire([limits(largest: 100, total: 1000, used: 10)])
    let inner = ScriptedCloud([.success(hello)])

    _ = try await WithinAllowance(inner, api: YandexApi(token: "t0ken", wire: wire))
      .kept(scratch.file, as: "IMG_0001.HEIC")

    let asked = await wire.asked()
    #expect(
      asked.map { $0.url.absoluteString } == [
        "https://cloud-api.yandex.net/v1/disk?fields=max_file_size,total_space,used_space",
      ]
    )
    #expect(asked.map { $0.headers["Authorization"] } == ["OAuth t0ken"])
  }

  @Test("refuses a file larger than the Disk accepts, without uploading it")
  func tooLarge() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let wire = ScriptedWire([limits(largest: 4, total: 1000, used: 10)])
    let inner = ScriptedCloud([])

    await #expect(throws: TooLargeForCloud.self) {
      try await WithinAllowance(inner, api: YandexApi(token: "t0ken", wire: wire))
        .kept(scratch.file, as: "IMG_0001.HEIC")
    }

    #expect(await inner.received().isEmpty)
  }

  @Test("refuses a file the Disk has no room for, without uploading it")
  func noRoom() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let wire = ScriptedWire([limits(largest: 100, total: 1000, used: 996)])
    let inner = ScriptedCloud([])

    await #expect(throws: CloudFull.self) {
      try await WithinAllowance(inner, api: YandexApi(token: "t0ken", wire: wire))
        .kept(scratch.file, as: "IMG_0001.HEIC")
    }

    #expect(await inner.received().isEmpty)
  }

  @Test("accepts a file that exactly fills the remaining space")
  func exactFit() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let wire = ScriptedWire([limits(largest: 5, total: 1000, used: 995)])
    let inner = ScriptedCloud([.success(hello)])

    let kept = try await WithinAllowance(inner, api: YandexApi(token: "t0ken", wire: wire))
      .kept(scratch.file, as: "IMG_0001.HEIC")

    #expect(kept == hello)
  }

  @Test("uploads anyway when the token may not read the limits")
  func limitsForbidden() async throws {
    let scratch = try Scratch(Data("hello".utf8))
    defer { scratch.remove() }
    let wire = ScriptedWire([Response(status: 403, body: Data(#"{"error":"ForbiddenError"}"#.utf8))])
    let inner = ScriptedCloud([.success(hello)])

    let kept = try await WithinAllowance(inner, api: YandexApi(token: "t0ken", wire: wire))
      .kept(scratch.file, as: "IMG_0001.HEIC")

    #expect(kept == hello)
  }

  @Test("names the file and explains the limit when refusing")
  func wording() async throws {
    let scratch = try Scratch(Data(repeating: 7, count: 3000))
    defer { scratch.remove() }
    let wire = ScriptedWire([limits(largest: 2000, total: 1_000_000, used: 0)])
    let inner = ScriptedCloud([])

    let failure = await #expect(throws: TooLargeForCloud.self) {
      try await WithinAllowance(inner, api: YandexApi(token: "t0ken", wire: wire))
        .kept(scratch.file, as: "clip.mov")
    }

    #expect(failure?.description.hasPrefix("clip.mov is 3") == true)
    #expect(failure?.description.contains("accepts files up to 2") == true)
  }
}
