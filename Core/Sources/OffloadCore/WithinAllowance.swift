import Foundation

/// A depot that first checks the file fits what the user's Yandex Disk accepts.
///
/// The Disk limits the size of a single file (1 GB without a paid plan) and,
/// of course, the space left. Finding that out before the upload saves
/// sending gigabytes only to be refused. A token that may not read the
/// account's limits skips the check, and the upload itself then decides.
public struct WithinAllowance: Depot {
  private let origin: any Depot
  private let api: YandexApi

  /// - Parameters:
  ///   - origin: The depot that takes the file.
  ///   - api: The Disk API to ask for the limits.
  public init(_ origin: any Depot, api: YandexApi) {
    self.origin = origin
    self.api = api
  }

  public func door(for name: String, bytes: Int64) async throws -> Request {
    let limits = try await api.response(
      resource: "disk",
      query: ["fields": "max_file_size,total_space,used_space"]
    )
    if limits.status == 200,
      let allowance = try? JSONDecoder().decode(Allowance.self, from: limits.body)
    {
      guard bytes <= allowance.largest else {
        throw TooLargeForCloud(name: name, size: bytes, limit: allowance.largest)
      }
      guard bytes <= allowance.total - allowance.used else {
        throw CloudFull(name: name, size: bytes, free: allowance.total - allowance.used)
      }
    }
    return try await origin.door(for: name, bytes: bytes)
  }

  public func shelved(_ name: String) async throws -> [Fingerprint] {
    try await origin.shelved(name)
  }

  public func dated(_ name: String, at taken: Date) async throws {
    try await origin.dated(name, at: taken)
  }
}

/// A file is larger than the cloud account accepts for a single file.
public struct TooLargeForCloud: LocalizedError, CustomStringConvertible, Verdict {
  private let name: String
  private let size: Int64
  private let limit: Int64

  init(name: String, size: Int64, limit: Int64) {
    self.name = name
    self.size = size
    self.limit = limit
  }

  public var description: String {
    "\(name) is \(Bytes(size)), but this Yandex Disk account accepts files up to \(Bytes(limit))"
  }

  public var errorDescription: String? {
    description
  }
}

/// The cloud account has less free space than a file needs.
public struct CloudFull: LocalizedError, CustomStringConvertible, Verdict {
  private let name: String
  private let size: Int64
  private let free: Int64

  init(name: String, size: Int64, free: Int64) {
    self.name = name
    self.size = size
    self.free = free
  }

  public var description: String {
    "\(name) is \(Bytes(size)), but this Yandex Disk has only \(Bytes(free)) free"
  }

  public var errorDescription: String? {
    description
  }
}

/// A count of bytes written the way people read file sizes.
struct Bytes: CustomStringConvertible {
  private let count: Int64

  init(_ count: Int64) {
    self.count = count
  }

  var description: String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
  }
}

// Decodable requires readable stored properties; this only mirrors the API's JSON.
private struct Allowance: Decodable {
  let largest: Int64
  let total: Int64
  let used: Int64

  private enum CodingKeys: String, CodingKey {
    case largest = "max_file_size"
    case total = "total_space"
    case used = "used_space"
  }
}
