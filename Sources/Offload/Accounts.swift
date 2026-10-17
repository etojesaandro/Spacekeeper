import Foundation
import Observation
import OffloadCore
import os

/// A cloud the user can keep originals in, with the user's sign-in to it.
protocol Account: Sendable {
  /// How the choice of this cloud is remembered.
  func key() -> String

  /// The cloud's name, as the user knows it.
  func name() -> String

  /// Whether the user is signed in.
  func signedIn() -> Bool

  /// Where originals go, talking through the wire.
  func depot(through wire: any Wire) throws -> any Depot

  /// What the cloud keeps, talking through the wire.
  func archive(through wire: any Wire) throws -> any Archive

  /// Forgets the user's sign-in.
  func signOut() async
}

/// Yandex Disk, reached with the token Yandex handed out.
struct YandexAccount: Account {
  private let token: KeychainToken

  /// - Parameter token: Where the Yandex Disk token is kept.
  init(token: KeychainToken) {
    self.token = token
  }

  func key() -> String {
    "yandex"
  }

  func name() -> String {
    "Yandex Disk"
  }

  func signedIn() -> Bool {
    (try? token.value()) != nil
  }

  func depot(through wire: any Wire) throws -> any Depot {
    let api = YandexApi(token: try token.value(), wire: wire)
    return WithinAllowance(YandexDisk(api: api), api: api)
  }

  func archive(through wire: any Wire) throws -> any Archive {
    YandexDisk(token: try token.value(), wire: wire)
  }

  /// Keeps the token Yandex handed out.
  func keep(_ secret: String) throws {
    try token.keep(secret)
  }

  func signOut() async {
    token.forget()
  }
}

/// Google Drive, reached with access tokens bought with the kept refresh token.
///
/// The folders found on the Drive are remembered for as long as the same
/// user stays signed in, so that every upload does not look them up again.
struct GoogleAccount: Account {
  private let client: String
  private let refresh: KeychainToken
  private let bearer: GoogleBearer
  private let wire: any Wire
  private let trees = OSAllocatedUnfairLock(initialState: [String: DriveTree]())

  /// - Parameters:
  ///   - client: The client ID of the app's iOS client at Google.
  ///   - refresh: Where the refresh token is kept.
  ///   - wire: Network that tokens are bought through.
  init(client: String, refresh: KeychainToken, wire: any Wire) {
    self.client = client
    self.refresh = refresh
    self.bearer = GoogleBearer(tokens: GoogleTokens(client: client, wire: wire), refresh: refresh)
    self.wire = wire
  }

  func key() -> String {
    "google"
  }

  func name() -> String {
    "Google Drive"
  }

  func signedIn() -> Bool {
    (try? refresh.value()) != nil
  }

  func depot(through wire: any Wire) throws -> any Depot {
    try drive(through: wire)
  }

  func archive(through wire: any Wire) throws -> any Archive {
    try drive(through: wire)
  }

  /// A new sign-in, with a fresh secret, for the user to go through.
  func signIn() -> GoogleSignIn {
    GoogleSignIn(client: client)
  }

  /// Trades the code Google returned for tokens and keeps the one that lasts.
  func keep(_ code: String, from signIn: GoogleSignIn) async throws {
    let grant = try await signIn.grant(for: code, through: wire)
    guard !grant.refresh.isEmpty else {
      throw NoRefresh()
    }
    try refresh.keep(grant.refresh)
  }

  func signOut() async {
    // Google is told too, so the app no longer shows among the account's connected apps.
    if let kept = try? refresh.value() {
      var parts = URLComponents(string: "https://oauth2.googleapis.com/revoke")!
      parts.queryItems = [URLQueryItem(name: "token", value: kept)]
      _ = try? await wire.response(
        to: Request(
          method: "POST",
          url: URL(string: "https://oauth2.googleapis.com/revoke")!,
          headers: ["Content-Type": "application/x-www-form-urlencoded"],
          body: Data((parts.percentEncodedQuery ?? "").utf8)
        )
      )
    }
    refresh.forget()
  }

  private func drive(through wire: any Wire) throws -> GoogleDrive {
    let kept = try refresh.value()
    let api = GoogleApi(bearer: bearer, wire: wire)
    let tree = trees.withLock { trees in
      if let known = trees[kept] {
        return known
      }
      let fresh = DriveTree(api: api, top: "Offload")
      trees = [kept: fresh]
      return fresh
    }
    return GoogleDrive(api: api, tree: tree)
  }
}

extension KeychainToken: Secret {}

/// Google signed the user in but handed out no token that lasts.
struct NoRefresh: LocalizedError {
  var errorDescription: String? {
    "Google did not allow lasting access. Sign out of Offload in your Google account and try again."
  }
}

/// Which cloud the user keeps originals in, remembered across runs of the app.
///
/// It may be asked from any thread, as uploads go on in the background.
struct Choice: Sendable {
  private let accounts: [any Account]
  private let key = "Offload.cloud"

  /// - Parameter accounts: The clouds to choose from; the first is chosen until the user picks.
  init(accounts: [any Account]) {
    precondition(!accounts.isEmpty, "There must be a cloud to choose")
    self.accounts = accounts
  }

  /// The chosen cloud.
  func account() -> any Account {
    let chosen = UserDefaults.standard.string(forKey: key)
    return accounts.first { $0.key() == chosen } ?? accounts[0]
  }

  /// Every cloud there is to choose from.
  func all() -> [any Account] {
    accounts
  }

  /// Makes the cloud the chosen one.
  func choose(_ account: any Account) {
    UserDefaults.standard.set(account.key(), forKey: key)
  }
}

/// The cloud chosen at the moment something is asked of it.
///
/// Uploads outlive a single run of the app, and the user may sign in or
/// out in between, so the cloud and its sign-in are looked up anew for
/// every question.
struct ChosenCloud: Depot, Archive {
  private let choice: Choice
  private let wire: any Wire

  /// - Parameters:
  ///   - choice: Which cloud is chosen.
  ///   - wire: Network to talk through.
  init(choice: Choice, wire: any Wire) {
    self.choice = choice
    self.wire = wire
  }

  func door(for name: String, bytes: Int64) async throws -> Request {
    try await depot().door(for: name, bytes: bytes)
  }

  func shelved(_ name: String) async throws -> [Fingerprint] {
    try await depot().shelved(name)
  }

  func dated(_ name: String, at taken: Date) async throws {
    try await depot().dated(name, at: taken)
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

  private func depot() throws -> any Depot {
    try choice.account().depot(through: wire)
  }

  private func archive() throws -> any Archive {
    try choice.account().archive(through: wire)
  }
}

/// The clouds as the screen follows them: which is chosen and who is signed in.
@MainActor
@Observable
final class Clouds {
  /// The name of the chosen cloud.
  private(set) var name: String
  /// Whether the user is signed in to the chosen cloud.
  private(set) var connected: Bool
  private let choice: Choice

  /// - Parameter choice: Which cloud is chosen.
  init(choice: Choice) {
    self.choice = choice
    self.name = choice.account().name()
    self.connected = choice.account().signedIn()
  }

  /// The chosen cloud.
  func chosen() -> any Account {
    choice.account()
  }

  /// Every cloud there is to choose from.
  func all() -> [any Account] {
    choice.all()
  }

  /// Makes the cloud the chosen one.
  func choose(_ account: any Account) {
    choice.choose(account)
    noticed()
  }

  /// Someone signed in or out; the screen is brought up to date.
  func noticed() {
    name = choice.account().name()
    connected = choice.account().signedIn()
  }
}
