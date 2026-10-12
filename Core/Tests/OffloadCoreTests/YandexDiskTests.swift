import Foundation
import OffloadCore
import Testing

@Suite("Yandex Disk")
struct YandexDiskTests {
  private let link = Response(
    status: 200,
    body: Data(
      #"{"href":"https://uploader.example/put/42","method":"PUT","templated":false}"#.utf8
    )
  )
  private let created = Response(status: 201, body: Data())
  private let accepted = Response(status: 202, body: Data())
  private let missing = Response(status: 404, body: Data(#"{"error":"DiskNotFoundError"}"#.utf8))
  private let details = Response(
    status: 200,
    body: Data(#"{"size":5,"md5":"5d41402abc4b2a76b9719d911017c592"}"#.utf8)
  )
  private let hello = Fingerprint(bytes: 5, md5: "5d41402abc4b2a76b9719d911017c592")
  private let local = URL(fileURLWithPath: "/tmp/IMG_0001.MOV")

  /// A Disk that uploads under the final name and does not wait between tries.
  private func plain(_ wire: ScriptedWire) -> YandexDisk {
    YandexDisk(
      api: YandexApi(token: "t0ken", wire: wire),
      folder: "app:/",
      disguise: Disguise(suffix: "", exempt: []),
      patience: Patience(tries: 3, pause: .zero)
    )
  }

  /// A Disk that uploads under a neutral extension and does not wait between tries.
  private func disguised(_ wire: ScriptedWire) -> YandexDisk {
    YandexDisk(
      api: YandexApi(token: "t0ken", wire: wire),
      folder: "app:/",
      disguise: Disguise(suffix: ".offload", exempt: []),
      patience: Patience(tries: 3, pause: .zero)
    )
  }

  @Test("reports the size and MD5 the Disk recorded for the uploaded file")
  func reportsFingerprint() async throws {
    let wire = ScriptedWire([link, created, details])

    let kept = try await plain(wire).kept(local, as: "IMG_0001.MOV")

    #expect(kept == hello)
  }

  @Test("asks for a link, sends the file to it, then reads the stored details")
  func callSequence() async throws {
    let wire = ScriptedWire([link, created, details])

    _ = try await plain(wire).kept(local, as: "IMG_0001.MOV")

    let asked = await wire.asked()
    let sent = await wire.sent()
    #expect(
      asked.map { "\($0.method) \($0.url.absoluteString)" } == [
        "GET https://cloud-api.yandex.net/v1/disk/resources/upload"
          + "?overwrite=true&path=app:/IMG_0001.MOV",
        "PUT https://uploader.example/put/42",
        "GET https://cloud-api.yandex.net/v1/disk/resources"
          + "?fields=size,md5&path=app:/IMG_0001.MOV",
      ]
    )
    #expect(sent == [local])
  }

  @Test("uploads under a neutral extension and renames, so a video is not slowed down")
  func disguisedSequence() async throws {
    let wire = ScriptedWire([link, created, details, created, details])

    let kept = try await disguised(wire).kept(local, as: "IMG_0001.MOV")

    let asked = await wire.asked()
    #expect(kept == hello)
    #expect(
      asked.map { "\($0.method) \($0.url.absoluteString)" } == [
        "GET https://cloud-api.yandex.net/v1/disk/resources/upload"
          + "?overwrite=true&path=app:/IMG_0001.MOV.offload",
        "PUT https://uploader.example/put/42",
        "GET https://cloud-api.yandex.net/v1/disk/resources"
          + "?fields=size,md5&path=app:/IMG_0001.MOV.offload",
        "POST https://cloud-api.yandex.net/v1/disk/resources/move"
          + "?from=app:/IMG_0001.MOV.offload&overwrite=true&path=app:/IMG_0001.MOV",
        "GET https://cloud-api.yandex.net/v1/disk/resources"
          + "?fields=size,md5&path=app:/IMG_0001.MOV",
      ]
    )
  }

  @Test("uploads a picture under its own name, with no rename, by default")
  func pictureTravelsPlain() async throws {
    let wire = ScriptedWire([link, created, details])

    let kept = try await YandexDisk(token: "t0ken", wire: wire).kept(local, as: "IMG_0001.HEIC")

    let asked = await wire.asked()
    #expect(kept == hello)
    #expect(
      asked.map { "\($0.method) \($0.url.absoluteString)" } == [
        "GET https://cloud-api.yandex.net/v1/disk/resources/upload"
          + "?overwrite=true&path=app:/IMG_0001.HEIC",
        "PUT https://uploader.example/put/42",
        "GET https://cloud-api.yandex.net/v1/disk/resources"
          + "?fields=size,md5&path=app:/IMG_0001.HEIC",
      ]
    )
  }

  @Test("disguises a video by default")
  func videoTravelsDisguised() async throws {
    let wire = ScriptedWire([link, created, details, created, details])

    _ = try await YandexDisk(token: "t0ken", wire: wire).kept(local, as: "IMG_0001.MOV")

    let asked = await wire.asked()
    #expect(asked[0].url.absoluteString.hasSuffix("path=app:/IMG_0001.MOV.offload"))
    #expect(asked.count == 5)
  }

  @Test("waits for a rename the Disk finishes after it has answered")
  func slowRename() async throws {
    let wire = ScriptedWire([link, created, details, accepted, missing, details])

    let kept = try await disguised(wire).kept(local, as: "IMG_0001.MOV")

    #expect(kept == hello)
  }

  @Test("fails when the Disk refuses the rename")
  func renameRefused() async throws {
    let locked = Response(status: 423, body: Data(#"{"error":"DiskResourceLockedError"}"#.utf8))
    let wire = ScriptedWire([link, created, details, locked])

    let failure = await #expect(throws: CloudRefusal.self) {
      try await disguised(wire).kept(local, as: "IMG_0001.MOV")
    }

    #expect(failure?.description.contains("Rename after upload refused with HTTP 423") == true)
  }

  @Test("sends the token to the API but never to the upload link")
  func tokenScope() async throws {
    let wire = ScriptedWire([link, created, details])

    _ = try await plain(wire).kept(local, as: "IMG_0001.MOV")

    let asked = await wire.asked()
    #expect(asked.map { $0.headers["Authorization"] } == ["OAuth t0ken", nil, "OAuth t0ken"])
  }

  @Test("escapes characters that would change the meaning of the path")
  func escapesName() async throws {
    let wire = ScriptedWire([link, created, details])

    _ = try await plain(wire).kept(local, as: "a+b &c.mov")

    let asked = await wire.asked()
    #expect(asked[0].url.absoluteString.hasSuffix("path=app:/a%2Bb%20%26c.mov"))
  }

  @Test("waits for a file the Disk has received but not yet filed away")
  func acceptedUpload() async throws {
    let wire = ScriptedWire([link, accepted, missing, missing, details])

    let kept = try await plain(wire).kept(local, as: "IMG_0001.MOV")

    #expect(kept == hello)
  }

  @Test("gives up when the uploaded file never appears")
  func neverAppears() async throws {
    let wire = ScriptedWire([link, accepted, missing, missing, missing])

    let failure = await #expect(throws: CloudRefusal.self) {
      try await plain(wire).kept(local, as: "IMG_0001.MOV")
    }

    #expect(failure?.description.contains("Stored file details refused with HTTP 404") == true)
  }

  @Test("does not keep asking when reading the stored file is refused outright")
  func detailsRefused() async throws {
    let wire = ScriptedWire([link, created, Response(status: 401, body: Data())])

    let failure = await #expect(throws: CloudRefusal.self) {
      try await plain(wire).kept(local, as: "IMG_0001.MOV")
    }

    #expect(failure?.description.contains("401") == true)
    #expect(await wire.asked().count == 3)
  }

  @Test("fails without uploading when the Disk refuses to issue a link")
  func linkRefused() async throws {
    let conflict = Response(
      status: 409,
      body: Data(#"{"error":"DiskResourceAlreadyExistsError"}"#.utf8)
    )
    let wire = ScriptedWire([conflict])

    let failure = await #expect(throws: CloudRefusal.self) {
      try await plain(wire).kept(local, as: "IMG_0001.MOV")
    }

    let sent = await wire.sent()
    #expect(sent.isEmpty)
    #expect(failure?.description.contains("409") == true)
    #expect(failure?.description.contains("DiskResourceAlreadyExistsError") == true)
  }

  @Test("fails when the Disk has no room for the file")
  func uploadRefused() async throws {
    let wire = ScriptedWire([link, Response(status: 507, body: Data())])

    let failure = await #expect(throws: CloudRefusal.self) {
      try await plain(wire).kept(local, as: "IMG_0001.MOV")
    }

    #expect(failure?.description.contains("507") == true)
  }

  @Test("fails on a templated upload link rather than guessing how to fill it")
  func templatedLink() async throws {
    let templated = Response(
      status: 200,
      body: Data(#"{"href":"https://uploader.example/{id}","method":"PUT","templated":true}"#.utf8)
    )
    let wire = ScriptedWire([templated])

    let failure = await #expect(throws: UnusableUploadLink.self) {
      try await plain(wire).kept(local, as: "IMG_0001.MOV")
    }

    #expect(failure?.localizedDescription.contains("https://uploader.example/{id}") == true)
    #expect(failure?.stands() == true)
  }

  @Test("hands out the upload link as a request that carries no token")
  func door() async throws {
    let wire = ScriptedWire([link])

    let door = try await disguised(wire).door(for: "IMG_0001.MOV", bytes: 5)

    let asked = await wire.asked()
    let expected = URL(string: "https://uploader.example/put/42")!
    #expect(door == Request(method: "PUT", url: expected, headers: [:]))
    #expect(
      asked.map { "\($0.method) \($0.url.absoluteString)" } == [
        "GET https://cloud-api.yandex.net/v1/disk/resources/upload"
          + "?overwrite=true&path=app:/IMG_0001.MOV.offload",
      ]
    )
  }

  @Test("tells what it holds under a name")
  func shelvedPlain() async throws {
    let wire = ScriptedWire([details])

    let held = try await plain(wire).shelved("IMG_0001.MOV")

    #expect(held == [hello])
    #expect(await wire.asked().count == 1)
  }

  @Test("holds nothing under a name it does not know")
  func shelvedNothing() async throws {
    let wire = ScriptedWire([missing])

    let held = try await plain(wire).shelved("IMG_0001.MOV")

    #expect(held.isEmpty)
  }

  @Test("renames a file that arrived in disguise before telling what it holds")
  func shelvedDisguised() async throws {
    let wire = ScriptedWire([details, created, details])

    let held = try await disguised(wire).shelved("IMG_0001.MOV")

    let asked = await wire.asked()
    #expect(held == [hello])
    #expect(
      asked.map { "\($0.method) \($0.url.absoluteString)" } == [
        "GET https://cloud-api.yandex.net/v1/disk/resources"
          + "?fields=size,md5&path=app:/IMG_0001.MOV.offload",
        "POST https://cloud-api.yandex.net/v1/disk/resources/move"
          + "?from=app:/IMG_0001.MOV.offload&overwrite=true&path=app:/IMG_0001.MOV",
        "GET https://cloud-api.yandex.net/v1/disk/resources"
          + "?fields=size,md5&path=app:/IMG_0001.MOV",
      ]
    )
  }

  @Test("finds a file whose rename was already done on an earlier look")
  func shelvedRenamed() async throws {
    let wire = ScriptedWire([missing, details])

    let held = try await disguised(wire).shelved("IMG_0001.MOV")

    let asked = await wire.asked()
    #expect(held == [hello])
    #expect(asked.map { $0.method } == ["GET", "GET"])
  }

  @Test("holds nothing while a disguised file has not arrived")
  func shelvedNotArrived() async throws {
    let wire = ScriptedWire([missing, missing])

    let held = try await disguised(wire).shelved("IMG_0001.MOV")

    #expect(held.isEmpty)
  }

  @Test("fails rather than guess when asking what it holds is refused")
  func shelvedRefused() async throws {
    let wire = ScriptedWire([Response(status: 401, body: Data())])

    let failure = await #expect(throws: CloudRefusal.self) {
      try await plain(wire).shelved("IMG_0001.MOV")
    }

    #expect(failure?.stands() == true)
  }

  @Test(
    "takes a locked file, a busy or a failing server as passing troubles",
    arguments: [423, 429, 500, 503]
  )
  func passing(status: Int) async throws {
    let wire = ScriptedWire([Response(status: status, body: Data())])

    let failure = await #expect(throws: CloudRefusal.self) {
      try await plain(wire).shelved("IMG_0001.MOV")
    }

    #expect(failure?.stands() == false)
  }

  @Test("makes the folders a name leads through when the Disk misses them")
  func makesFolders() async throws {
    let noFolder = Response(status: 409, body: Data(#"{"error":"DiskPathDoesntExistsError"}"#.utf8))
    let exists = Response(
      status: 409,
      body: Data(#"{"error":"DiskPathPointsToExistentDirectoryError"}"#.utf8)
    )
    let wire = ScriptedWire([noFolder, exists, created, link])

    let door = try await plain(wire).door(for: "2025/03/IMG_0001.MOV", bytes: 5)

    let asked = await wire.asked()
    #expect(door.url.absoluteString == "https://uploader.example/put/42")
    #expect(
      asked.map { "\($0.method) \($0.url.absoluteString)" } == [
        "GET https://cloud-api.yandex.net/v1/disk/resources/upload"
          + "?overwrite=true&path=app:/2025/03/IMG_0001.MOV",
        "PUT https://cloud-api.yandex.net/v1/disk/resources?path=app:/2025",
        "PUT https://cloud-api.yandex.net/v1/disk/resources?path=app:/2025/03",
        "GET https://cloud-api.yandex.net/v1/disk/resources/upload"
          + "?overwrite=true&path=app:/2025/03/IMG_0001.MOV",
      ]
    )
  }

  @Test("makes the folders as well when the Disk reports them as not found")
  func makesFoldersOnNotFound() async throws {
    let wire = ScriptedWire([missing, created, created, link])

    _ = try await plain(wire).door(for: "2025/03/IMG_0001.MOV", bytes: 5)

    #expect(await wire.asked().map { $0.method } == ["GET", "PUT", "PUT", "GET"])
  }

  @Test("makes no folders when the Disk has them already")
  func foldersThere() async throws {
    let wire = ScriptedWire([link])

    _ = try await plain(wire).door(for: "2025/03/IMG_0001.MOV", bytes: 5)

    #expect(await wire.asked().count == 1)
  }

  @Test("fails when the Disk refuses to make a folder")
  func folderRefused() async throws {
    let noFolder = Response(status: 409, body: Data(#"{"error":"DiskPathDoesntExistsError"}"#.utf8))
    let wire = ScriptedWire([noFolder, Response(status: 507, body: Data())])

    let failure = await #expect(throws: CloudRefusal.self) {
      try await plain(wire).door(for: "2025/03/IMG_0001.MOV", bytes: 5)
    }

    #expect(failure?.description.contains("Folder app:/2025 refused with HTTP 507") == true)
  }

  @Test("fails when the link is still refused after the folders are made")
  func linkRefusedAfterFolders() async throws {
    let conflict = Response(status: 409, body: Data(#"{"error":"DiskPathDoesntExistsError"}"#.utf8))
    let wire = ScriptedWire([conflict, created, created, conflict])

    let failure = await #expect(throws: CloudRefusal.self) {
      try await plain(wire).door(for: "2025/03/IMG_0001.MOV", bytes: 5)
    }

    #expect(failure?.description.contains("Upload link refused with HTTP 409") == true)
  }

  @Test("renames a disguised file within its folder")
  func shelvedInFolder() async throws {
    let wire = ScriptedWire([details, created, details])

    _ = try await disguised(wire).shelved("2025/03/IMG_0001.MOV")

    let asked = await wire.asked()
    #expect(
      asked[1].url.absoluteString
        == "https://cloud-api.yandex.net/v1/disk/resources/move"
        + "?from=app:/2025/03/IMG_0001.MOV.offload&overwrite=true&path=app:/2025/03/IMG_0001.MOV"
    )
  }

  @Test("notes when the original was made, under the name rclone reads")
  func dated() async throws {
    let wire = ScriptedWire([details])

    try await plain(wire).dated(
      "2025/03/IMG_0001.MOV",
      at: Date(timeIntervalSince1970: 1_741_600_072.5)
    )

    let asked = await wire.asked()
    #expect(
      asked.map { "\($0.method) \($0.url.absoluteString)" } == [
        "PATCH https://cloud-api.yandex.net/v1/disk/resources?path=app:/2025/03/IMG_0001.MOV"
      ]
    )
    #expect(
      String(decoding: asked[0].body, as: UTF8.self)
        == #"{"custom_properties":{"rclone_modified":"2025-03-10T09:47:52.500Z"}}"#
    )
    #expect(asked[0].headers["Content-Type"] == "application/json")
    #expect(asked[0].headers["Authorization"] == "OAuth t0ken")
  }

  @Test("fails when the Disk refuses to note the date")
  func dateRefused() async throws {
    let wire = ScriptedWire([missing])

    let failure = await #expect(throws: CloudRefusal.self) {
      try await plain(wire).dated("IMG_0001.MOV", at: Date(timeIntervalSince1970: 1))
    }

    #expect(failure?.description.contains("Date of the original refused with HTTP 404") == true)
  }
}
