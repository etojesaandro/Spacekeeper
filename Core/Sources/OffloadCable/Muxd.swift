import Foundation

/// The service of the computer that carries connections to phones over their cable.
///
/// Linux runs it as usbmuxd, macOS has it built in, and on Windows it comes
/// with Apple Devices or iTunes. Each request goes over a fresh channel: a
/// message out, a message back. A channel that asked to connect to a phone
/// then carries bytes to and from that phone's port as they are.
public struct Muxd: Sendable {
  private let doorway: any Doorway

  /// - Parameter doorway: Where the service listens.
  public init(doorway: any Doorway) {
    self.doorway = doorway
  }

  /// The phones plugged in with a cable, as the service sees them now.
  public func phones() throws -> [Phone] {
    let channel = try doorway.opened()
    defer {
      channel.close()
    }
    let answer = try MuxMessage(fields: ["MessageType": "ListDevices"]).exchanged(over: channel)
    let list = answer.value(of: "DeviceList") as? [Any] ?? []
    return list.compactMap { entry in
      guard
        let entry = entry as? [String: Any],
        let facts = entry["Properties"] as? [String: Any],
        facts["ConnectionType"] as? String == "USB",
        let number = Number(entry["DeviceID"]).value()
      else {
        return nil
      }
      return Phone(number: number, serial: facts["SerialNumber"] as? String ?? "")
    }
  }

  /// Whether the phone trusts this computer, as far as the service can tell.
  ///
  /// A phone talks through its cable only to a computer it trusts, and the
  /// service keeps a pairing record for each such phone. The service may name
  /// the phone with or without the dash its identifier has, so both are asked.
  public func trust(of phone: Phone) -> Trust {
    var refused = false
    for name in phone.names() {
      do {
        let channel = try doorway.opened()
        defer {
          channel.close()
        }
        let answer = try MuxMessage(
          fields: ["MessageType": "ReadPairRecord", "PairRecordID": name]
        ).exchanged(over: channel)
        if answer.value(of: "PairRecordData") != nil {
          return .given
        }
        refused = refused || (Number(answer.value(of: "Number")).value() ?? 0) != 0
      } catch {
        return .unknown
      }
    }
    return refused ? .missing : .unknown
  }

  /// A channel to a port of the phone.
  public func tunnel(to phone: Phone, port: UInt16) throws -> any Channel {
    let channel = try doorway.opened()
    do {
      let answer = try MuxMessage(
        fields: [
          "MessageType": "Connect",
          "DeviceID": phone.number,
          // The service expects the port in network byte order, read as a plain number.
          "PortNumber": Int(port.bigEndian),
        ]
      ).exchanged(over: channel)
      let result = Number(answer.value(of: "Number")).value() ?? -1
      guard result == 0 else {
        throw TunnelRefused(port: port, result: result)
      }
      return channel
    } catch {
      channel.close()
      throw error
    }
  }
}

/// A phone the service carries connections to.
public struct Phone: Sendable, Equatable {
  fileprivate let number: Int
  private let serial: String

  /// - Parameters:
  ///   - number: How the service tells this phone from others while it is plugged in.
  ///   - serial: The phone's own identifier.
  public init(number: Int, serial: String) {
    self.number = number
    self.serial = serial
  }

  /// The names the service may file the phone's pairing record under.
  fileprivate func names() -> [String] {
    let plain = serial.filter { $0 != "-" }
    // Newer phones have identifiers of 24 letters, written with a dash after the eighth.
    guard plain.count == 24 else {
      return [serial]
    }
    let dashed = "\(plain.prefix(8))-\(plain.dropFirst(8))"
    return [serial] + [dashed, plain].filter { $0 != serial }
  }
}

/// Whether a phone trusts the computer it is plugged into.
public enum Trust: Sendable, Equatable {
  /// The phone trusts the computer.
  case given

  /// The service holds no pairing record: the phone has not been asked, or said no.
  case missing

  /// The service could not tell.
  case unknown
}

/// One message of the service's protocol: a 16-byte header and a property list.
struct MuxMessage {
  private let fields: [String: Any]

  init(fields: [String: Any]) {
    self.fields = fields
  }

  /// The message as it goes over the channel.
  func bytes() throws -> Data {
    var all = fields
    all["ClientVersionString"] = "offload-backup"
    all["ProgName"] = "offload-backup"
    let body = try PropertyListSerialization.data(fromPropertyList: all, format: .xml, options: 0)
    var bytes = Data()
    // Length including this header, protocol version 1, message type 8 (property list), tag.
    for word in [UInt32(16 + body.count), 1, 8, 1] {
      withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) }
    }
    bytes.append(body)
    return bytes
  }

  /// Sends the message and reads the answer.
  func exchanged(over channel: any Channel) throws -> MuxAnswer {
    try channel.send(bytes())
    let head = try channel.received(exactly: 16, what: "an answer of usbmuxd")
    let length = head.prefix(4).enumerated().reduce(0) { sum, byte in
      sum | Int(byte.element) << (8 * byte.offset)
    }
    guard length >= 16, length < 1 << 24 else {
      throw MuxGarbled()
    }
    let body = try channel.received(exactly: length - 16, what: "an answer of usbmuxd")
    guard
      let fields = try? PropertyListSerialization.propertyList(from: body, format: nil)
        as? [String: Any]
    else {
      throw MuxGarbled()
    }
    return MuxAnswer(fields: fields)
  }
}

/// What the service answered.
struct MuxAnswer {
  private let fields: [String: Any]

  init(fields: [String: Any]) {
    self.fields = fields
  }

  func value(of key: String) -> Any? {
    fields[key]
  }
}

/// A whole number out of a property list, which may arrive as any kind of number.
struct Number {
  private let raw: Any?

  init(_ raw: Any?) {
    self.raw = raw
  }

  func value() -> Int? {
    if let number = raw as? Int {
      return number
    }
    if let number = raw as? NSNumber {
      return number.intValue
    }
    return nil
  }
}

/// The service answered with something that is not its protocol.
public struct MuxGarbled: LocalizedError, CustomStringConvertible {
  public var description: String {
    "usbmuxd answered with something unreadable"
  }

  public var errorDescription: String? {
    description
  }
}

/// The service could not connect to the port of the phone.
public struct TunnelRefused: LocalizedError, CustomStringConvertible {
  private let port: UInt16
  private let result: Int

  init(port: UInt16, result: Int) {
    self.port = port
    self.result = result
  }

  /// Whether the phone is there but nothing listens at the port.
  public func unanswered() -> Bool {
    result == 3
  }

  public var description: String {
    switch result {
    case 2:
      "The phone was unplugged"
    case 3:
      "Nothing on the phone answers at port \(port)"
    default:
      "usbmuxd could not connect to port \(port) of the phone (result \(result))"
    }
  }

  public var errorDescription: String? {
    description
  }
}
