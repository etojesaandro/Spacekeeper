import Foundation
import SpacekeeperCore
import Testing

@testable import SpacekeeperCable

@Suite("usbmuxd, the service that carries connections over the cable")
struct MuxdTests {
  @Test("Lists only the phones plugged in with a cable")
  func phonesUsb() throws {
    let channel = ScriptedChannel(
      answer: try MuxReply([
        "DeviceList": [
          [
            "DeviceID": 4,
            "MessageType": "Attached",
            "Properties": ["ConnectionType": "USB", "DeviceID": 4, "SerialNumber": "AAA"],
          ],
          [
            "DeviceID": 9,
            "MessageType": "Attached",
            "Properties": ["ConnectionType": "Network", "DeviceID": 9, "SerialNumber": "BBB"],
          ],
        ]
      ]).bytes()
    )

    let phones = try Muxd(doorway: ArrangedDoorway([channel])).phones()

    #expect(phones == [Phone(number: 4, serial: "AAA")])
  }

  @Test("Asks for the list with a property list framed by a 16-byte header")
  func phonesFraming() throws {
    let channel = ScriptedChannel(answer: try MuxReply(["DeviceList": [Any]()]).bytes())

    _ = try Muxd(doorway: ArrangedDoorway([channel])).phones()

    let sent = SentMessage(channel.sent())
    #expect(sent.header() == [UInt32(channel.sent().count), 1, 8, 1])
    #expect(sent.fields()["MessageType"] as? String == "ListDevices")
    #expect(channel.shut())
  }

  @Test("Asks to connect to the port in network byte order")
  func tunnelPort() throws {
    let channel = ScriptedChannel(answer: try MuxReply(["MessageType": "Result", "Number": 0]).bytes())

    _ = try Muxd(doorway: ArrangedDoorway([channel])).tunnel(
      to: Phone(number: 4, serial: "AAA"),
      port: 47810
    )

    let fields = SentMessage(channel.sent()).fields()
    #expect(fields["MessageType"] as? String == "Connect")
    #expect(Number(fields["DeviceID"]).value() == 4)
    #expect(Number(fields["PortNumber"]).value() == 0xC2BA)
    #expect(!channel.shut())
  }

  @Test("Tells when nothing on the phone answers at the port")
  func tunnelRefused() throws {
    let channel = ScriptedChannel(answer: try MuxReply(["MessageType": "Result", "Number": 3]).bytes())

    let refusal = #expect(throws: TunnelRefused.self) {
      try Muxd(doorway: ArrangedDoorway([channel])).tunnel(
        to: Phone(number: 4, serial: "AAA"),
        port: 47810
      )
    }

    #expect(refusal?.unanswered() == true)
    #expect(channel.shut())
  }

  @Test("Refuses an answer whose header claims an impossible length")
  func garbled() throws {
    let channel = ScriptedChannel(answer: Data(repeating: 0, count: 16))

    #expect(throws: MuxGarbled.self) {
      try Muxd(doorway: ArrangedDoorway([channel])).phones()
    }
  }

  @Test("Fails when the service stops in the middle of an answer")
  func cutShort() throws {
    let channel = ScriptedChannel(answer: try MuxReply(["DeviceList": [Any]()]).bytes().prefix(20))

    #expect(throws: ChannelEnded.self) {
      try Muxd(doorway: ArrangedDoorway([channel])).phones()
    }
  }
}

@Suite("HTTP to a phone's port through the cable")
struct TunnelWireTests {
  private func wire(_ answer: String) throws -> (TunnelWire, ScriptedChannel) {
    let channel = ScriptedChannel(
      answer: try MuxReply(["MessageType": "Result", "Number": 0]).bytes() + Data(answer.utf8)
    )
    return (
      TunnelWire(
        muxd: Muxd(doorway: ArrangedDoorway([channel])),
        phone: Phone(number: 4, serial: "AAA"),
        port: 47810
      ),
      channel
    )
  }

  @Test("Sends the request line with its query, the headers and an end to the head")
  func requestHead() async throws {
    let (wire, channel) = try wire("HTTP/1.1 200 OK\r\n\r\n")

    _ = try await wire.response(
      to: Request(
        method: "GET",
        url: URL(string: "http://iphone/pieces?id=A%2B1")!,
        headers: ["X-Spacekeeper-Code": "123456"]
      )
    )

    let sent = String(decoding: channel.sent(), as: UTF8.self)
    let head = String(sent[sent.range(of: "GET")!.lowerBound...])
    #expect(
      head == "GET /pieces?id=A%2B1 HTTP/1.1\r\nHost: iphone\r\nX-Spacekeeper-Code: 123456\r\n"
        + "Content-Length: 0\r\nConnection: close\r\n\r\n"
    )
    #expect(channel.shut())
  }

  @Test("Reads the status and a body that lasts until the phone closes")
  func bodyToEnd() async throws {
    let (wire, _) = try wire("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\nWrong code")

    let response = try await wire.response(
      to: Request(method: "GET", url: URL(string: "http://iphone/items")!, headers: [:])
    )

    #expect(response.status == 403)
    #expect(String(decoding: response.body, as: UTF8.self) == "Wrong code")
  }

  @Test("Stops at the length the answer names")
  func bodyLength() async throws {
    let (wire, _) = try wire("HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabcdef")

    let response = try await wire.response(
      to: Request(method: "GET", url: URL(string: "http://iphone/items")!, headers: [:])
    )

    #expect(String(decoding: response.body, as: UTF8.self) == "abc")
  }

  @Test("Writes the body of a download into the file")
  func saving() async throws {
    let (wire, _) = try wire("HTTP/1.1 200 OK\r\n\r\nphoto bytes")
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("spacekeeper-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: file)
    }

    let response = try await wire.response(
      to: Request(method: "GET", url: URL(string: "http://iphone/content")!, headers: [:]),
      saving: file
    )

    #expect(response.status == 200)
    #expect(try String(contentsOf: file, encoding: .utf8) == "photo bytes")
  }

  @Test("Sends the file of an upload after the head, with its length")
  func sending() async throws {
    let (wire, channel) = try wire("HTTP/1.1 200 OK\r\n\r\n")
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("spacekeeper-\(UUID().uuidString)")
    try Data("twelve bytes".utf8).write(to: file)
    defer {
      try? FileManager.default.removeItem(at: file)
    }

    _ = try await wire.response(
      to: Request(method: "POST", url: URL(string: "http://iphone/held")!, headers: [:]),
      sending: file
    )

    let sent = String(decoding: channel.sent(), as: UTF8.self)
    #expect(sent.contains("Content-Length: 12\r\n"))
    #expect(sent.hasSuffix("\r\n\r\ntwelve bytes"))
  }

  @Test("Fails when the phone closes before the head of its answer ends")
  func headCut() async throws {
    let (wire, _) = try wire("HTTP/1.1 200 OK\r\n")

    await #expect(throws: ChannelEnded.self) {
      try await wire.response(
        to: Request(method: "GET", url: URL(string: "http://iphone/items")!, headers: [:])
      )
    }
  }

  @Test("Fails when the phone answers with something other than HTTP")
  func notHttp() async throws {
    let (wire, _) = try wire("SSH-2.0-dropbear\r\n\r\n")

    await #expect(throws: GarbledAnswer.self) {
      try await wire.response(
        to: Request(method: "GET", url: URL(string: "http://iphone/items")!, headers: [:])
      )
    }
  }

  @Test("Fails when a body of named length ends early")
  func bodyCut() async throws {
    let (wire, _) = try wire("HTTP/1.1 200 OK\r\nContent-Length: 30\r\n\r\nshort")

    await #expect(throws: ChannelEnded.self) {
      try await wire.response(
        to: Request(method: "GET", url: URL(string: "http://iphone/items")!, headers: [:])
      )
    }
  }
}

@Suite("Backup through the cable, end to end")
struct CableBackupTests {
  @Test("Copies every file of the phone into the folder through the tunnel")
  func wholeRun() async throws {
    let item = MediaItem(
      id: "A1",
      name: "IMG_1.JPG",
      video: false,
      seconds: 0,
      created: Date(timeIntervalSince1970: 1),
      modified: Date(timeIntervalSince1970: 2),
      size: 9,
      local: 9
    )
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("spacekeeper-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: folder)
    }
    let muxd = Muxd(
      doorway: HatchDoorway(
        Hatch(stock: LittleStock([item], contents: ["A1": [Data("pixels".utf8)]]), code: "123456")
      )
    )

    let report = try await Backup(
      from: HttpHandset(
        wire: TunnelWire(muxd: muxd, phone: Phone(number: 1, serial: "X"), port: 47810),
        root: URL(string: "http://iphone/")!,
        code: "123456",
        reach: .device
      ),
      into: folder,
      ledger: Ledger(file: folder.appendingPathComponent(".spacekeeper-backup.json")),
      reach: .device,
      watched: Silent(),
      giveUp: 5
    ).run()

    #expect(report.copied == [item])
    #expect(
      try String(
        contentsOf: folder.appendingPathComponent("2024/05/A1_0.JPG"),
        encoding: .utf8
      ) == "pixels"
    )
  }
}

/// An onlooker who wants to hear nothing.
struct Silent: BackupOnlooker {
  func copying(_ number: Int, of count: Int, _ item: MediaItem) {}

  func failed(_ item: MediaItem, _ reason: String) {}
}

@Suite("Sockets of the operating system")
struct SocketTests {
  @Test("Tells that nobody listens at a port of this computer")
  func loopbackRefused() throws {
    let failure = #expect(throws: SocketFailure.self) {
      // Port 9 is the discard service, which no test machine runs.
      try LoopbackDoorway(port: 9, patience: 5).opened()
    }

    #expect(failure?.refused() == true)
  }

  #if !os(Windows)
  @Test("Tells that no service listens at a socket path")
  func unixMissing() throws {
    let failure = #expect(throws: SocketFailure.self) {
      try UnixDoorway(path: "/nonexistent/spacekeeper-\(UUID().uuidString)", patience: 5).opened()
    }

    #expect(failure?.refused() == true)
  }
  #endif
}

@Suite("Trust between the phone and this computer")
struct TrustTests {
  private let phone = Phone(number: 4, serial: "00008030-000A1B2C3D4E5F60")

  @Test("tells that the phone trusts the computer when the service holds a pairing record")
  func given() throws {
    let channel = ScriptedChannel(answer: try MuxReply(["PairRecordData": Data([1, 2])]).bytes())

    let trust = Muxd(doorway: ArrangedDoorway([channel])).trust(of: phone)

    #expect(trust == .given)
    let fields = SentMessage(channel.sent()).fields()
    #expect(fields["MessageType"] as? String == "ReadPairRecord")
    #expect(fields["PairRecordID"] as? String == "00008030-000A1B2C3D4E5F60")
  }

  @Test("asks again without the dash, as the service may file the record that way")
  func undashed() throws {
    let first = ScriptedChannel(answer: try MuxReply(["MessageType": "Result", "Number": 2]).bytes())
    let second = ScriptedChannel(answer: try MuxReply(["PairRecordData": Data([1])]).bytes())

    let trust = Muxd(doorway: ArrangedDoorway([first, second])).trust(of: phone)

    #expect(trust == .given)
    #expect(SentMessage(second.sent()).fields()["PairRecordID"] as? String == "00008030000A1B2C3D4E5F60")
  }

  @Test("tells that trust is missing when no name has a pairing record")
  func missing() throws {
    let refusals = try (0..<2).map { _ in
      ScriptedChannel(answer: try MuxReply(["MessageType": "Result", "Number": 2]).bytes())
    }

    let trust = Muxd(doorway: ArrangedDoorway(refusals)).trust(of: phone)

    #expect(trust == .missing)
  }

  @Test("cannot tell when the service does not answer the question")
  func unknown() throws {
    let trust = Muxd(doorway: ArrangedDoorway([])).trust(of: phone)

    #expect(trust == .unknown)
  }

  @Test("asks once for a phone whose name has no dash to add")
  func oldName() throws {
    let channel = ScriptedChannel(answer: try MuxReply(["MessageType": "Result", "Number": 2]).bytes())

    let trust = Muxd(doorway: ArrangedDoorway([channel])).trust(of: Phone(number: 1, serial: "abc"))

    #expect(trust == .missing)
  }
}
