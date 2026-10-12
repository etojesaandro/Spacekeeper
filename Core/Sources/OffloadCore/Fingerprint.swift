/// Size and MD5 of a file's content.
///
/// Two copies hold the same content when their fingerprints are equal.
public struct Fingerprint: Equatable, Sendable, CustomStringConvertible {
  private let bytes: Int64
  private let md5: String

  /// - Parameters:
  ///   - bytes: Length of the content in bytes.
  ///   - md5: MD5 of the content as hexadecimal text, in any letter case.
  public init(bytes: Int64, md5: String) {
    self.bytes = bytes
    self.md5 = md5
  }

  public var description: String {
    "\(bytes) bytes, md5 \(md5.lowercased())"
  }

  public static func == (left: Fingerprint, right: Fingerprint) -> Bool {
    left.bytes == right.bytes && left.md5.lowercased() == right.md5.lowercased()
  }
}
