import Foundation

/// Yandex's sign-in for one registered application.
///
/// The user grants access on a Yandex page; Yandex then sends the browser
/// to its own "verification code" address with the token in the part of the
/// address after `#`. That is the only return address Yandex offers to
/// applications registered for API access, so whoever shows the page has to
/// watch the addresses it visits and hand each of them to `outcome(of:)`.
public struct YandexSignIn: Sendable {
  private let client: String
  private let host: String

  /// - Parameters:
  ///   - client: The application's ClientID from Yandex OAuth.
  ///   - host: Host of Yandex OAuth.
  public init(client: String, host: String) {
    self.client = client
    self.host = host
  }

  /// Signs in at the international Yandex OAuth address.
  public init(client: String) {
    self.init(client: client, host: "oauth.yandex.com")
  }

  /// Address of the page where the user grants access.
  public func page() -> URL {
    var parts = URLComponents()
    parts.scheme = "https"
    parts.host = host
    parts.path = "/authorize"
    parts.queryItems = [
      URLQueryItem(name: "response_type", value: "token"),
      URLQueryItem(name: "client_id", value: client),
    ]
    return parts.url!
  }

  /// What an address the sign-in page went to means for the sign-in.
  public func outcome(of address: URL) -> Outcome {
    // Yandex answers on either of its two hosts, whichever one was asked.
    guard
      [host, "oauth.yandex.com", "oauth.yandex.ru"].contains(address.host ?? ""),
      address.scheme == "https",
      address.path == "/verification_code"
    else {
      return .elsewhere
    }
    let parts = URLComponents(url: address, resolvingAgainstBaseURL: false)
    let facts = (items(parts?.percentEncodedFragment) + items(parts?.percentEncodedQuery))
      .reduce(into: [String: String]()) { $0[$1.name] = $1.value ?? "" }
    if let token = facts["access_token"], !token.isEmpty {
      return .granted(token)
    }
    return .refused(
      facts["error_description"] ?? facts["error"] ?? "Yandex returned no token"
    )
  }

  private func items(_ encoded: String?) -> [URLQueryItem] {
    var parts = URLComponents()
    parts.percentEncodedQuery = encoded
    return parts.queryItems ?? []
  }

  /// What an address means for a sign-in in progress.
  public enum Outcome: Sendable, Equatable {
    /// An ordinary page on the way; the sign-in goes on.
    case elsewhere

    /// The user granted access; this is the token.
    case granted(String)

    /// Access was not granted, for the reason given.
    case refused(String)
  }
}
