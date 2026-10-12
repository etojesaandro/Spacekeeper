import Foundation
import OffloadCore

/// The Yandex Disk of whoever is signed in at the moment something is asked of it.
///
/// Uploads outlive a single run of the app, and the user may sign in or out
/// in between, so the token is looked up anew for every question.
struct SignedInDisk: Depot, Archive {
  private let token: KeychainToken
  private let wire: any Wire

  /// - Parameters:
  ///   - token: Where the Yandex Disk token is kept.
  ///   - wire: Network to talk through.
  init(token: KeychainToken, wire: any Wire) {
    self.token = token
    self.wire = wire
  }

  func door(for name: String, bytes: Int64) async throws -> Request {
    try await disk().door(for: name, bytes: bytes)
  }

  func shelved(_ name: String) async throws -> [Fingerprint] {
    try await disk().shelved(name)
  }

  func dated(_ name: String, at taken: Date) async throws {
    try await disk().dated(name, at: taken)
  }

  func shelf(_ path: String) async throws -> Shelf {
    try await archive().shelf(path)
  }

  func thumbnail(of file: KeptFile) async throws -> Data {
    try await archive().thumbnail(of: file)
  }

  func picture(of file: KeptFile) async throws -> Data {
    try await archive().picture(of: file)
  }

  func fetched(_ file: KeptFile, into place: URL) async throws {
    try await archive().fetched(file, into: place)
  }

  private func disk() throws -> any Depot {
    let api = YandexApi(token: try token.value(), wire: wire)
    return WithinAllowance(YandexDisk(api: api), api: api)
  }

  private func archive() throws -> any Archive {
    YandexDisk(token: try token.value(), wire: wire)
  }
}
