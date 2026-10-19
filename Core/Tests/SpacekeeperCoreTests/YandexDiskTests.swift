import Foundation
import SpacekeeperCore
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

  private func kept(_ path: String, preview: [URL]) -> KeptFile {
    KeptFile(path: path, bytes: 5, print: hello, made: [], preview: preview)
  }

  @Test("lists the folders and files of a folder, with what it knows of each file")
  func shelf() async throws {
    let page = Response(
      status: 200,
      body: Data(
        #"""
        {"_embedded":{"total":4,"items":[
          {"name":"03","type":"dir"},
          {"name":"a.MOV","type":"file","size":5,"md5":"5d41402abc4b2a76b9719d911017c592",
           "preview":"https://downloader.disk.yandex.ru/preview/1",
           "custom_properties":{"rclone_modified":"2025-03-10T09:47:52.500Z","other":7}},
          {"name":"b.JPG","type":"file","size":5,"md5":"5d41402abc4b2a76b9719d911017c592"},
          {"name":"c.MOV.offload","type":"file","size":9,"md5":"00"}
        ]}}
        """#.utf8
      )
    )
    let wire = ScriptedWire([page])

    let shelf = try await YandexDisk(token: "t0ken", wire: wire).shelf("2025")

    let asked = await wire.asked()
    #expect(shelf.folders() == ["2025/03"])
    #expect(
      shelf == Shelf(
        folders: ["2025/03"],
        files: [
          KeptFile(
            path: "2025/a.MOV",
            bytes: 5,
            print: hello,
            made: [Date(timeIntervalSince1970: 1_741_600_072.5)],
            preview: [URL(string: "https://downloader.disk.yandex.ru/preview/1")!]
          ),
          KeptFile(path: "2025/b.JPG", bytes: 5, print: hello, made: [], preview: []),
        ]
      )
    )
    #expect(
      asked.map { $0.url.absoluteString } == [
        "https://cloud-api.yandex.net/v1/disk/resources"
          + "?fields=_embedded.total,_embedded.items.name,_embedded.items.type,"
          + "_embedded.items.size,_embedded.items.md5,_embedded.items.preview,"
          + "_embedded.items.custom_properties"
          + "&limit=500&offset=0&path=app:/2025&preview_crop=true&preview_size=S&sort=name",
      ]
    )
  }

  @Test("reads a long folder page by page")
  func shelfPages() async throws {
    func page(_ name: String) -> Response {
      Response(
        status: 200,
        body: Data(
          (#"{"_embedded":{"total":2,"items":["#
            + #"{"name":"\#(name)","type":"file","size":1,"md5":"a"}]}}"#).utf8
        )
      )
    }
    let wire = ScriptedWire([page("a.JPG"), page("b.JPG")])

    let shelf = try await plain(wire).shelf("")

    let asked = await wire.asked()
    #expect(shelf.originals().map { $0.name() } == ["a.JPG", "b.JPG"])
    #expect(asked.map { $0.url.absoluteString.contains("offset=1&path=app:/&") } == [false, true])
  }

  @Test("stops reading a folder that turns out shorter than announced")
  func shelfShort() async throws {
    let empty = Response(status: 200, body: Data(#"{"_embedded":{"total":9,"items":[]}}"#.utf8))
    let wire = ScriptedWire([empty])

    let shelf = try await plain(wire).shelf("")

    #expect(shelf == Shelf(folders: [], files: []))
  }

  @Test("fails when the Disk refuses to list a folder")
  func shelfRefused() async throws {
    let wire = ScriptedWire([missing])

    let failure = await #expect(throws: CloudRefusal.self) {
      try await plain(wire).shelf("2025")
    }

    #expect(failure?.description.contains("List of kept files refused with HTTP 404") == true)
  }

  @Test("shows the small picture the Disk made, sending the token to Yandex's own host")
  func thumbnail() async throws {
    let wire = ScriptedWire([Response(status: 200, body: Data("jpeg".utf8))])
    let file = kept("a.MOV", preview: [URL(string: "https://downloader.disk.yandex.ru/p/1")!])

    let picture = try await plain(wire).thumbnail(of: file)

    let asked = await wire.asked()
    #expect(picture == Data("jpeg".utf8))
    #expect(asked.map { $0.headers["Authorization"] } == ["OAuth t0ken"])
  }

  @Test(
    "never sends the token to a host that is not Yandex's, or without encryption",
    arguments: [
      "https://example.com/p/1", "https://notyandex.ru/p/1", "http://downloader.disk.yandex.ru/p/1",
    ]
  )
  func thumbnailElsewhere(address: String) async throws {
    let wire = ScriptedWire([Response(status: 200, body: Data("jpeg".utf8))])

    _ = try await plain(wire).thumbnail(of: kept("a.MOV", preview: [URL(string: address)!]))

    #expect(await wire.asked().map { $0.headers["Authorization"] } == [nil])
  }

  @Test("has no small picture of a file the Disk made none for")
  func noThumbnail() async throws {
    let wire = ScriptedWire([])

    let failure = await #expect(throws: NoPicture.self) {
      try await plain(wire).thumbnail(of: kept("2025/a.plist", preview: []))
    }

    #expect(failure?.localizedDescription == "Yandex Disk has no picture of a.plist")
  }

  @Test("fails when the picture cannot be read")
  func thumbnailRefused() async throws {
    let wire = ScriptedWire([Response(status: 403, body: Data())])
    let file = kept("a.MOV", preview: [URL(string: "https://downloader.disk.yandex.ru/p/1")!])

    await #expect(throws: CloudRefusal.self) {
      try await plain(wire).thumbnail(of: file)
    }
  }

  @Test("asks for a large picture of a file and shows it")
  func picture() async throws {
    let facts = Response(
      status: 200,
      body: Data(#"{"preview":"https://downloader.disk.yandex.ru/p/xl"}"#.utf8)
    )
    let wire = ScriptedWire([facts, Response(status: 200, body: Data("big".utf8))])

    let picture = try await plain(wire).picture(of: kept("2025/a.MOV", preview: []))

    let asked = await wire.asked()
    #expect(picture == Data("big".utf8))
    #expect(
      asked.map { $0.url.absoluteString } == [
        "https://cloud-api.yandex.net/v1/disk/resources"
          + "?fields=preview&path=app:/2025/a.MOV&preview_size=XL",
        "https://downloader.disk.yandex.ru/p/xl",
      ]
    )
  }

  @Test("has no large picture when the Disk offers none or refuses")
  func noPicture() async throws {
    let none = ScriptedWire([Response(status: 200, body: Data("{}".utf8))])
    let refused = ScriptedWire([missing])

    await #expect(throws: NoPicture.self) {
      try await plain(none).picture(of: kept("a.plist", preview: []))
    }
    await #expect(throws: CloudRefusal.self) {
      try await plain(refused).picture(of: kept("a.plist", preview: []))
    }
  }

  @Test("fetches a file through a download link, which takes no token")
  func fetched() async throws {
    let scratch = try Scratch(Data())
    defer { scratch.remove() }
    let wire = ScriptedWire([link, Response(status: 200, body: Data("hello".utf8))])

    try await plain(wire).fetched(kept("2025/a.MOV", preview: []), into: scratch.file)

    let asked = await wire.asked()
    #expect(try Data(contentsOf: scratch.file) == Data("hello".utf8))
    #expect(
      asked.map { $0.url.absoluteString } == [
        "https://cloud-api.yandex.net/v1/disk/resources/download?path=app:/2025/a.MOV",
        "https://uploader.example/put/42",
      ]
    )
    #expect(asked.map { $0.headers["Authorization"] } == ["OAuth t0ken", nil])
  }

  @Test("fails when the Disk gives no download link, a useless one, or no file")
  func fetchRefused() async throws {
    let scratch = try Scratch(Data())
    defer { scratch.remove() }
    let templated = Response(
      status: 200,
      body: Data(#"{"href":"https://d.example/{id}","method":"GET","templated":true}"#.utf8)
    )
    let file = kept("a.MOV", preview: [])

    await #expect(throws: CloudRefusal.self) {
      try await plain(ScriptedWire([missing])).fetched(file, into: scratch.file)
    }
    await #expect(throws: UnusableUploadLink.self) {
      try await plain(ScriptedWire([templated])).fetched(file, into: scratch.file)
    }
    await #expect(throws: CloudRefusal.self) {
      try await plain(ScriptedWire([link, missing])).fetched(file, into: scratch.file)
    }
  }
}
