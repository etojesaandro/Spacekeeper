import Crypto
import Foundation

/// Fingerprint of a file on the local disk.
///
/// The file is read through one fixed buffer, so a multi-gigabyte video
/// never sits in memory.
public struct FingerprintOf: Sendable {
  private let file: URL
  private let chunk: Int

  /// - Parameters:
  ///   - file: Location of the file to read.
  ///   - chunk: Size of the read buffer in bytes.
  public init(_ file: URL, chunk: Int) {
    self.file = file
    self.chunk = chunk
  }

  /// Reads the file in one-megabyte pieces.
  public init(_ file: URL) {
    self.init(file, chunk: 1 << 20)
  }

  /// Reads the whole file and tells its fingerprint.
  public func value() throws -> Fingerprint {
    guard let stream = fopen(file.path, "rb") else {
      throw UnreadableFile(file: file)
    }
    defer {
      fclose(stream)
    }
    var hash = Insecure.MD5()
    var bytes: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: chunk)
    while true {
      let count = fread(&buffer, 1, buffer.count, stream)
      if count == 0 {
        break
      }
      buffer.withUnsafeBytes { raw in
        hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[..<count]))
      }
      bytes += Int64(count)
    }
    guard ferror(stream) == 0 else {
      throw UnreadableFile(file: file)
    }
    return Fingerprint(
      bytes: bytes,
      md5: hash.finalize().map { String(format: "%02x", $0) }.joined()
    )
  }
}

/// A local file could not be opened or read to its end.
public struct UnreadableFile: LocalizedError, CustomStringConvertible {
  private let file: URL

  init(file: URL) {
    self.file = file
  }

  public var description: String {
    "Cannot read \(file.path)"
  }

  public var errorDescription: String? {
    description
  }
}
