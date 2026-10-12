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
  private let details = Response(
    status: 200,
    body: Data(#"{"size":5,"md5":"5d41402abc4b2a76b9719d911017c592"}"#.utf8)
  )
  private let local = URL(fileURLWithPath: "/tmp/IMG_0001.HEIC")

  @Test("reports the size and MD5 the Disk recorded for the uploaded file")
  func reportsFingerprint() async throws {
    let wire = ScriptedWire([link, created, details])

    let kept = try await YandexDisk(token: "t0ken", wire: wire).kept(local, as: "IMG_0001.HEIC")

    #expect(kept == Fingerprint(bytes: 5, md5: "5d41402abc4b2a76b9719d911017c592"))
  }

  @Test("asks for a link, sends the file to it, then reads the stored details")
  func callSequence() async throws {
    let wire = ScriptedWire([link, created, details])

    _ = try await YandexDisk(token: "t0ken", wire: wire).kept(local, as: "IMG_0001.HEIC")

    let asked = await wire.asked()
    let sent = await wire.sent()
    #expect(
      asked.map { "\($0.method) \($0.url.absoluteString)" } == [
        "GET https://cloud-api.yandex.net/v1/disk/resources/upload"
          + "?overwrite=true&path=app:/IMG_0001.HEIC",
        "PUT https://uploader.example/put/42",
        "GET https://cloud-api.yandex.net/v1/disk/resources"
          + "?fields=size,md5&path=app:/IMG_0001.HEIC",
      ]
    )
    #expect(sent == [local])
  }

  @Test("sends the token to the API but never to the upload link")
  func tokenScope() async throws {
    let wire = ScriptedWire([link, created, details])

    _ = try await YandexDisk(token: "t0ken", wire: wire).kept(local, as: "IMG_0001.HEIC")

    let asked = await wire.asked()
    #expect(asked.map { $0.headers["Authorization"] } == ["OAuth t0ken", nil, "OAuth t0ken"])
  }

  @Test("escapes characters that would change the meaning of the path")
  func escapesName() async throws {
    let wire = ScriptedWire([link, created, details])

    _ = try await YandexDisk(token: "t0ken", wire: wire).kept(local, as: "a+b &c.mov")

    let asked = await wire.asked()
    #expect(asked[0].url.absoluteString.hasSuffix("path=app:/a%2Bb%20%26c.mov"))
  }

  @Test("accepts an upload the Disk has received but not yet filed")
  func acceptedUpload() async throws {
    let wire = ScriptedWire([link, Response(status: 202, body: Data()), details])

    let kept = try await YandexDisk(token: "t0ken", wire: wire).kept(local, as: "IMG_0001.HEIC")

    #expect(kept == Fingerprint(bytes: 5, md5: "5d41402abc4b2a76b9719d911017c592"))
  }

  @Test("fails without uploading when the Disk refuses to issue a link")
  func linkRefused() async throws {
    let conflict = Response(
      status: 409,
      body: Data(#"{"error":"DiskResourceAlreadyExistsError"}"#.utf8)
    )
    let wire = ScriptedWire([conflict])

    let failure = await #expect(throws: CloudRefusal.self) {
      try await YandexDisk(token: "t0ken", wire: wire).kept(local, as: "IMG_0001.HEIC")
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
      try await YandexDisk(token: "t0ken", wire: wire).kept(local, as: "IMG_0001.HEIC")
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

    await #expect(throws: UnusableUploadLink.self) {
      try await YandexDisk(token: "t0ken", wire: wire).kept(local, as: "IMG_0001.HEIC")
    }
  }
}
