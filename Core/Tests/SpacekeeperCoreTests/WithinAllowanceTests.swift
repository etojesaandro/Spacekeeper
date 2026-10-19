import Foundation
import SpacekeeperCore
import Testing

@Suite("Within the Yandex Disk allowance")
struct WithinAllowanceTests {
  private func limits(largest: Int, total: Int, used: Int) -> Response {
    Response(
      status: 200,
      body: Data(
        #"{"max_file_size":\#(largest),"total_space":\#(total),"used_space":\#(used)}"#.utf8
      )
    )
  }

  @Test("opens the door for a file that fits both the file limit and the free space")
  func fits() async throws {
    let wire = ScriptedWire([limits(largest: 100, total: 1000, used: 10)])
    let inner = ArrangedDepot([:])

    let door = try await WithinAllowance(inner, api: YandexApi(token: "t0ken", wire: wire))
      .door(for: "IMG_0001.HEIC", bytes: 5)

    #expect(door.url.absoluteString == "https://uploader.example/1")
    #expect(await inner.opened() == ["IMG_0001.HEIC"])
  }

  @Test("asks the Disk for its limits with the user's token")
  func asksLimits() async throws {
    let wire = ScriptedWire([limits(largest: 100, total: 1000, used: 10)])

    _ = try await WithinAllowance(ArrangedDepot([:]), api: YandexApi(token: "t0ken", wire: wire))
      .door(for: "IMG_0001.HEIC", bytes: 5)

    let asked = await wire.asked()
    #expect(
      asked.map { $0.url.absoluteString } == [
        "https://cloud-api.yandex.net/v1/disk?fields=max_file_size,total_space,used_space",
      ]
    )
    #expect(asked.map { $0.headers["Authorization"] } == ["OAuth t0ken"])
  }

  @Test("refuses a file larger than the Disk accepts, without opening a door")
  func tooLarge() async throws {
    let wire = ScriptedWire([limits(largest: 4, total: 1000, used: 10)])
    let inner = ArrangedDepot([:])

    await #expect(throws: TooLargeForCloud.self) {
      try await WithinAllowance(inner, api: YandexApi(token: "t0ken", wire: wire))
        .door(for: "IMG_0001.HEIC", bytes: 5)
    }

    #expect(await inner.opened().isEmpty)
  }

  @Test("refuses a file the Disk has no room for, without opening a door")
  func noRoom() async throws {
    let wire = ScriptedWire([limits(largest: 100, total: 1000, used: 996)])
    let inner = ArrangedDepot([:])

    await #expect(throws: CloudFull.self) {
      try await WithinAllowance(inner, api: YandexApi(token: "t0ken", wire: wire))
        .door(for: "IMG_0001.HEIC", bytes: 5)
    }

    #expect(await inner.opened().isEmpty)
  }

  @Test("accepts a file that exactly fills the remaining space")
  func exactFit() async throws {
    let wire = ScriptedWire([limits(largest: 5, total: 1000, used: 995)])
    let inner = ArrangedDepot([:])

    _ = try await WithinAllowance(inner, api: YandexApi(token: "t0ken", wire: wire))
      .door(for: "IMG_0001.HEIC", bytes: 5)

    #expect(await inner.opened() == ["IMG_0001.HEIC"])
  }

  @Test("opens the door anyway when the token may not read the limits")
  func limitsForbidden() async throws {
    let wire = ScriptedWire([
      Response(status: 403, body: Data(#"{"error":"ForbiddenError"}"#.utf8)),
    ])
    let inner = ArrangedDepot([:])

    _ = try await WithinAllowance(inner, api: YandexApi(token: "t0ken", wire: wire))
      .door(for: "IMG_0001.HEIC", bytes: 5_000_000_000)

    #expect(await inner.opened() == ["IMG_0001.HEIC"])
  }

  @Test("names the file and explains the limit when refusing")
  func wording() async throws {
    let wire = ScriptedWire([limits(largest: 2000, total: 1_000_000, used: 0)])

    let failure = await #expect(throws: TooLargeForCloud.self) {
      try await WithinAllowance(
        ArrangedDepot([:]),
        api: YandexApi(token: "t0ken", wire: wire)
      ).door(for: "clip.mov", bytes: 3000)
    }

    #expect(failure?.description.hasPrefix("clip.mov is 3") == true)
    #expect(failure?.description.contains("accepts files up to 2") == true)
  }

  @Test("settles for good, so the file is not sent again and again")
  func settles() async throws {
    let wire = ScriptedWire([limits(largest: 4, total: 1000, used: 10)])

    let failure = await #expect(throws: TooLargeForCloud.self) {
      try await WithinAllowance(
        ArrangedDepot([:]),
        api: YandexApi(token: "t0ken", wire: wire)
      ).door(for: "clip.mov", bytes: 5)
    }

    #expect(failure?.stands() == true)
  }

  @Test("passes on what the depot holds without asking for the limits")
  func shelved() async throws {
    let hello = Fingerprint(bytes: 5, md5: "5d41402abc4b2a76b9719d911017c592")
    let wire = ScriptedWire([])

    let held = try await WithinAllowance(
      ArrangedDepot(["IMG_0001.HEIC": [[hello]]]),
      api: YandexApi(token: "t0ken", wire: wire)
    ).shelved("IMG_0001.HEIC")

    #expect(held == [hello])
    #expect(await wire.asked().isEmpty)
  }

  @Test("passes the date of an original on without asking for the limits")
  func dated() async throws {
    let wire = ScriptedWire([])
    let inner = ArrangedDepot([:])

    try await WithinAllowance(inner, api: YandexApi(token: "t0ken", wire: wire))
      .dated("IMG_0001.HEIC", at: Date(timeIntervalSince1970: 7))

    #expect(await inner.noted() == ["IMG_0001.HEIC 7"])
    #expect(await wire.asked().isEmpty)
  }
}
