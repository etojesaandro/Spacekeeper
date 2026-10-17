import Foundation

#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

#if os(Windows)
typealias Descriptor = SOCKET
#else
typealias Descriptor = Int32
#endif

/// An open socket of the operating system.
///
/// Sending and receiving block the calling thread; one socket is used by
/// one thread at a time.
final class Socket: Channel, @unchecked Sendable {
  private let descriptor: Descriptor

  /// - Parameter descriptor: A connected socket, which this object now owns.
  init(descriptor: Descriptor) {
    self.descriptor = descriptor
  }

  func send(_ bytes: Data) throws {
    try bytes.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count {
        let start = raw.baseAddress!.advanced(by: offset)
        let left = raw.count - offset
        #if os(Windows)
        let sent = Int(
          WinSDK.send(
            descriptor,
            start.assumingMemoryBound(to: CChar.self),
            Int32(min(left, 1 << 30)),
            0
          )
        )
        #elseif canImport(Glibc)
        let sent = Glibc.send(descriptor, start, left, Int32(MSG_NOSIGNAL))
        #else
        let sent = Darwin.send(descriptor, start, left, 0)
        #endif
        if sent < 0, Fault().interrupted() {
          continue
        }
        guard sent > 0 else {
          throw SocketFailure(what: "send", fault: Fault())
        }
        offset += sent
      }
    }
  }

  func received(upTo count: Int) throws -> Data {
    var buffer = Data(count: max(count, 1))
    while true {
      let got = buffer.withUnsafeMutableBytes { raw -> Int in
        #if os(Windows)
        Int(
          WinSDK.recv(
            descriptor,
            raw.baseAddress!.assumingMemoryBound(to: CChar.self),
            Int32(min(raw.count, 1 << 30)),
            0
          )
        )
        #else
        recv(descriptor, raw.baseAddress, raw.count, 0)
        #endif
      }
      if got >= 0 {
        return buffer.prefix(got)
      }
      let fault = Fault()
      guard fault.interrupted() else {
        throw SocketFailure(what: "receive", fault: fault)
      }
    }
  }

  func close() {
    #if os(Windows)
    _ = closesocket(descriptor)
    #elseif canImport(Glibc)
    _ = Glibc.close(descriptor)
    #else
    _ = Darwin.close(descriptor)
    #endif
  }

  /// The same socket, which gives up receiving after so many silent seconds.
  func patient(_ seconds: Int) throws -> Socket {
    #if os(Windows)
    var wait = DWORD(seconds * 1000)
    let set = withUnsafeBytes(of: &wait) { raw in
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        raw.baseAddress!.assumingMemoryBound(to: CChar.self),
        Int32(raw.count)
      )
    }
    #else
    var wait = timeval(tv_sec: seconds, tv_usec: 0)
    let set = setsockopt(
      descriptor,
      SOL_SOCKET,
      SO_RCVTIMEO,
      &wait,
      socklen_t(MemoryLayout<timeval>.size)
    )
    #endif
    guard set == 0 else {
      let fault = Fault()
      close()
      throw SocketFailure(what: "set a time limit", fault: fault)
    }
    #if canImport(Darwin)
    // Darwin has no flag for each send that keeps a closed peer from killing the process.
    var quiet: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &quiet, socklen_t(MemoryLayout<Int32>.size))
    #endif
    return self
  }
}

/// The error number the operating system gave for the last failed socket call.
struct Fault: Sendable, CustomStringConvertible {
  private let number: Int32

  init(number: Int32) {
    self.number = number
  }

  /// The fault of the last socket call on this thread.
  init() {
    #if os(Windows)
    self.init(number: WSAGetLastError())
    #else
    self.init(number: errno)
    #endif
  }

  /// Whether the call was merely interrupted and is worth making again.
  func interrupted() -> Bool {
    #if os(Windows)
    number == WSAEINTR
    #else
    number == EINTR
    #endif
  }

  /// Whether the other end stayed silent longer than allowed.
  func silent() -> Bool {
    #if os(Windows)
    number == WSAETIMEDOUT
    #else
    number == EAGAIN || number == EWOULDBLOCK
    #endif
  }

  /// Whether nobody listens at the address.
  func refused() -> Bool {
    #if os(Windows)
    number == WSAECONNREFUSED
    #else
    number == ECONNREFUSED || number == ENOENT
    #endif
  }

  var description: String {
    #if os(Windows)
    "error \(number)"
    #else
    String(cString: strerror(number))
    #endif
  }
}

/// A socket call failed.
public struct SocketFailure: LocalizedError, CustomStringConvertible {
  private let what: String
  private let fault: Fault

  init(what: String, fault: Fault) {
    self.what = what
    self.fault = fault
  }

  /// Whether the failure means nobody listens where the socket was led.
  public func refused() -> Bool {
    fault.refused()
  }

  public var description: String {
    fault.silent() ? "No answer in time (\(what))" : "Cannot \(what): \(fault)"
  }

  public var errorDescription: String? {
    description
  }
}

#if !os(Windows)
/// A socket in the file system, such as the one usbmuxd listens at on Linux and macOS.
public struct UnixDoorway: Doorway {
  private let path: String
  private let patience: Int

  /// - Parameters:
  ///   - path: Where the socket lies.
  ///   - patience: Seconds to wait for an answer before giving up.
  public init(path: String, patience: Int) {
    self.path = path
    self.patience = patience
  }

  public func opened() throws -> any Channel {
    #if canImport(Glibc)
    let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    guard descriptor >= 0 else {
      throw SocketFailure(what: "open a socket", fault: Fault())
    }
    var address = sockaddr_un()
    #if canImport(Darwin)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    address.sun_family = sa_family_t(AF_UNIX)
    let name = Array(path.utf8)
    let fits = withUnsafeMutableBytes(of: &address.sun_path) { raw -> Bool in
      guard name.count < raw.count else {
        return false
      }
      raw.copyBytes(from: name)
      return true
    }
    guard fits else {
      Socket(descriptor: descriptor).close()
      throw SocketFailure(what: "reach \(path)", fault: Fault(number: ENAMETOOLONG))
    }
    let joined = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard joined == 0 else {
      let fault = Fault()
      Socket(descriptor: descriptor).close()
      throw SocketFailure(what: "reach \(path)", fault: fault)
    }
    return try Socket(descriptor: descriptor).patient(patience)
  }
}
#endif

/// A port of this computer reached over TCP, such as the one usbmuxd listens at on Windows.
public struct LoopbackDoorway: Doorway {
  private let port: UInt16
  private let patience: Int

  /// - Parameters:
  ///   - port: Port on 127.0.0.1.
  ///   - patience: Seconds to wait for an answer before giving up.
  public init(port: UInt16, patience: Int) {
    self.port = port
    self.patience = patience
  }

  public func opened() throws -> any Channel {
    #if os(Windows)
    var startup = WSADATA()
    // Winsock counts its starts, so starting it for every socket is harmless.
    guard WSAStartup(0x0202, &startup) == 0 else {
      throw SocketFailure(what: "start Winsock", fault: Fault())
    }
    let descriptor = WinSDK.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP.rawValue)
    guard descriptor != ~SOCKET(0) else {
      throw SocketFailure(what: "open a socket", fault: Fault())
    }
    var address = sockaddr_in()
    address.sin_family = ADDRESS_FAMILY(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
    let size = Int32(MemoryLayout<sockaddr_in>.size)
    #else
    #if canImport(Glibc)
    let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), Int32(IPPROTO_TCP))
    #else
    let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    #endif
    guard descriptor >= 0 else {
      throw SocketFailure(what: "open a socket", fault: Fault())
    }
    var address = sockaddr_in()
    #if canImport(Darwin)
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    let size = socklen_t(MemoryLayout<sockaddr_in>.size)
    #endif
    let joined = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, size)
      }
    }
    guard joined == 0 else {
      let fault = Fault()
      Socket(descriptor: descriptor).close()
      throw SocketFailure(what: "reach port \(port)", fault: fault)
    }
    return try Socket(descriptor: descriptor).patient(patience)
  }
}
