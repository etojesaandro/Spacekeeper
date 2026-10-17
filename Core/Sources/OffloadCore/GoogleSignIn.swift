import Crypto
import Foundation

/// Google's sign-in for one application registered as an iOS client.
///
/// The user grants access on a Google page, which then sends the browser to
/// the application's own address with a one-time code. The code, together
/// with the secret this sign-in made up beforehand, buys the tokens. An iOS
/// client has no secret of its own, so the made-up one (PKCE) is what keeps
/// a code that someone else catches worthless to them.
///
/// It asks only for files the application itself creates, the one Drive
/// access that Google grants without a security review of the application.
public struct GoogleSignIn: Sendable {
  private let client: String
  private let proof: Proof
  private let state: String

  /// - Parameters:
  ///   - client: The client ID of the iOS application, ending with
  ///     `.apps.googleusercontent.com`.
  ///   - proof: The secret of this one sign-in.
  ///   - state: Text that the return address must carry back, so that an
  ///     address from another sign-in is not taken for this one's.
  public init(client: String, proof: Proof, state: String) {
    self.client = client
    self.proof = proof
    self.state = state
  }

  /// A sign-in with a fresh secret and state.
  public init(client: String) {
    self.init(client: client, proof: Proof(), state: UUID().uuidString)
  }

  /// The scheme of the address Google returns to, which the app must claim.
  ///
  /// It is the client ID with its parts reversed, as Google prescribes.
  public func scheme() -> String {
    client.split(separator: ".").reversed().joined(separator: ".")
  }

  /// Address of the page where the user grants access.
  public func page() -> URL {
    var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    parts.queryItems = [
      URLQueryItem(name: "client_id", value: client),
      URLQueryItem(name: "redirect_uri", value: redirect()),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/drive.file"),
      URLQueryItem(name: "code_challenge", value: proof.challenge()),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
      URLQueryItem(name: "state", value: state),
    ]
    return parts.url!
  }

  /// What the address Google returned to means for the sign-in.
  public func outcome(of address: URL) -> Outcome {
    guard address.scheme == scheme() else {
      return .elsewhere
    }
    let facts = (URLComponents(url: address, resolvingAgainstBaseURL: false)?.queryItems ?? [])
      .reduce(into: [String: String]()) { $0[$1.name] = $1.value ?? "" }
    guard facts["state"] == state else {
      return .refused("Google returned to a sign-in that was not this one")
    }
    if let code = facts["code"], !code.isEmpty {
      return .granted(code)
    }
    return .refused(
      facts["error"] == "access_denied"
        ? "Access to Google Drive was not granted"
        : "Google returned no code: \(facts["error"] ?? "no reason given")"
    )
  }

  /// Trades the code Google returned for tokens.
  public func grant(for code: String, through wire: any Wire) async throws -> GoogleGrant {
    try await GoogleTokens(client: client, wire: wire).answer(
      to: [
        "grant_type": "authorization_code",
        "code": code,
        "code_verifier": proof.verifier(),
        "redirect_uri": redirect(),
      ],
      keeping: ""
    )
  }

  private func redirect() -> String {
    "\(scheme()):/oauth2redirect"
  }

  /// What an address means for a sign-in in progress.
  public enum Outcome: Sendable, Equatable {
    /// Not an address of this sign-in.
    case elsewhere

    /// The user granted access; this is the one-time code.
    case granted(String)

    /// Access was not granted, for the reason given.
    case refused(String)
  }
}

/// The secret of one sign-in, which only its hash travels with the user's browser.
public struct Proof: Sendable {
  private let text: String

  /// - Parameter text: Between 43 and 128 letters, digits and `-._~`.
  public init(text: String) {
    precondition((43...128).contains(text.count), "A PKCE verifier has 43 to 128 characters")
    self.text = text
  }

  /// A secret of 64 random characters.
  public init() {
    let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    var random = SystemRandomNumberGenerator()
    self.init(text: String((0..<64).map { _ in letters.randomElement(using: &random)! }))
  }

  func verifier() -> String {
    text
  }

  /// The SHA-256 of the secret in URL-safe Base64 without padding.
  func challenge() -> String {
    Data(SHA256.hash(data: Data(text.utf8))).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}

/// Tokens Google handed out: one to talk to Drive for an hour, one to get the next.
public struct GoogleGrant: Sendable, Equatable {
  /// The token Drive asks for, valid until `expiry`.
  public let access: String

  /// The token that buys new access tokens; it lasts until the user withdraws access.
  public let refresh: String

  /// When the access token stops working.
  public let expiry: Date

  public init(access: String, refresh: String, expiry: Date) {
    self.access = access
    self.refresh = refresh
    self.expiry = expiry
  }
}

/// Google's token endpoint for one application.
public struct GoogleTokens: Sendable {
  private let client: String
  private let wire: any Wire
  private let now: @Sendable () -> Date

  /// - Parameters:
  ///   - client: The client ID of the iOS application.
  ///   - wire: Network to talk through.
  ///   - now: The clock that dates the tokens' expiry.
  public init(client: String, wire: any Wire, now: @escaping @Sendable () -> Date) {
    self.client = client
    self.wire = wire
    self.now = now
  }

  public init(client: String, wire: any Wire) {
    self.init(client: client, wire: wire, now: { Date() })
  }

  /// A new access token for the refresh token.
  public func renewed(_ refresh: String) async throws -> GoogleGrant {
    try await answer(
      to: ["grant_type": "refresh_token", "refresh_token": refresh], keeping: refresh)
  }

  /// Asks the endpoint for tokens; a renewal answers without a refresh token, so the old one stays.
  func answer(to form: [String: String], keeping refresh: String) async throws -> GoogleGrant {
    var parts = URLComponents()
    parts.queryItems = (form.merging(["client_id": client]) { $1 })
      .sorted { $0.key < $1.key }
      .map { URLQueryItem(name: $0.key, value: $0.value) }
    let body = (parts.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    let asked = now()
    let answer = try await wire.response(
      to: Request(
        method: "POST",
        url: URL(string: "https://oauth2.googleapis.com/token")!,
        headers: ["Content-Type": "application/x-www-form-urlencoded"],
        body: Data(body.utf8)
      )
    )
    guard answer.status == 200 else {
      throw GoogleRefusal(
        step: "Google sign-in",
        response: answer,
        withdrawn: answer.status == 400
          && String(decoding: answer.body, as: UTF8.self).contains("invalid_grant")
      )
    }
    let tokens = try JSONDecoder().decode(TokenAnswer.self, from: answer.body)
    return GoogleGrant(
      access: tokens.access,
      refresh: tokens.refresh ?? refresh,
      // A minute is taken off, so a token is renewed before it can expire on the way.
      expiry: asked.addingTimeInterval(Double(tokens.lifetime) - 60)
    )
  }
}

/// Google answered with something other than success.
public struct GoogleRefusal: LocalizedError, CustomStringConvertible, Verdict {
  private let step: String
  private let response: Response
  private let withdrawn: Bool

  init(step: String, response: Response, withdrawn: Bool) {
    self.step = step
    self.response = response
    self.withdrawn = withdrawn
  }

  /// Whether the user withdrew access, so only signing in again helps.
  public func signedOut() -> Bool {
    withdrawn
  }

  public var description: String {
    "\(step) refused with HTTP \(response.status): "
      + String(decoding: response.body, as: UTF8.self)
  }

  public var errorDescription: String? {
    description
  }

  public func stands() -> Bool {
    response.status < 500 && response.status != 429
  }
}

// Decodable requires readable stored properties; this only mirrors Google's JSON.
private struct TokenAnswer: Decodable {
  let access: String
  let refresh: String?
  let lifetime: Int

  private enum CodingKeys: String, CodingKey {
    case access = "access_token"
    case refresh = "refresh_token"
    case lifetime = "expires_in"
  }
}
