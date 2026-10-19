import Foundation

/// A depot that first checks the file fits the space left on the user's Google Drive.
///
/// Drive shares its space with Gmail and Google Photos, and refuses a file
/// that does not fit only once all of it has been sent. Asking first saves
/// sending gigabytes for nothing. An account without a limit, or a quota
/// Drive will not tell, skips the check, and the upload itself then decides.
public struct WithinDriveQuota: Depot {
  private let origin: any Depot
  private let api: GoogleApi

  /// - Parameters:
  ///   - origin: The depot that takes the file.
  ///   - api: The Drive API to ask for the quota.
  public init(_ origin: any Depot, api: GoogleApi) {
    self.origin = origin
    self.api = api
  }

  public func door(for name: String, bytes: Int64) async throws -> Request {
    let about = try await api.response(
      method: "GET",
      resource: "about",
      query: ["fields": "storageQuota(limit,usage)"]
    )
    if about.status == 200,
      let quota = try? JSONDecoder().decode(About.self, from: about.body).storageQuota,
      let limit = quota.limit.flatMap({ Int64($0) }),
      let usage = quota.usage.flatMap({ Int64($0) })
    {
      guard bytes <= limit - usage else {
        throw CloudFull(name: name, size: bytes, free: max(limit - usage, 0), cloud: "Google Drive")
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

// Decodable requires readable stored properties; this only mirrors Drive's JSON,
// which writes the numbers as strings and leaves the limit out when there is none.
private struct About: Decodable {
  let storageQuota: Quota

  struct Quota: Decodable {
    let limit: String?
    let usage: String?
  }
}
