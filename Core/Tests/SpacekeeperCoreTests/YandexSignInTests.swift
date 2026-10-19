import Foundation
import SpacekeeperCore
import Testing

@Suite("Yandex sign-in")
struct YandexSignInTests {
  private let signIn = YandexSignIn(client: "abc123")

  @Test("sends the user to Yandex's page for a token, naming the application")
  func page() {
    #expect(
      signIn.page().absoluteString
        == "https://oauth.yandex.com/authorize?response_type=token&client_id=abc123"
    )
  }

  @Test("takes the token from the address Yandex returns to")
  func granted() {
    let back = URL(
      string: "https://oauth.yandex.com/verification_code"
        + "#access_token=y0_AgAAAA&token_type=bearer&expires_in=31536000"
    )!

    #expect(signIn.outcome(of: back) == .granted("y0_AgAAAA"))
  }

  @Test("accepts the return address on Yandex's Russian host as well")
  func grantedOnOtherHost() {
    let back = URL(string: "https://oauth.yandex.ru/verification_code#access_token=y0_AgAAAA")!

    #expect(signIn.outcome(of: back) == .granted("y0_AgAAAA"))
  }

  @Test("reports Yandex's own words when the user denies access")
  func denied() {
    let back = URL(
      string: "https://oauth.yandex.com/verification_code"
        + "#error=access_denied&error_description=User%20denied%20access"
    )!

    #expect(signIn.outcome(of: back) == .refused("User denied access"))
  }

  @Test("reads a refusal that arrives before the hash sign too")
  func deniedInQuery() {
    let back = URL(string: "https://oauth.yandex.com/verification_code?error=unauthorized_client")!

    #expect(signIn.outcome(of: back) == .refused("unauthorized_client"))
  }

  @Test("treats a return address without a token as a refusal")
  func noToken() {
    let back = URL(string: "https://oauth.yandex.com/verification_code")!

    #expect(signIn.outcome(of: back) == .refused("Yandex returned no token"))
  }

  @Test(
    "lets every other page pass",
    arguments: [
      "https://oauth.yandex.com/authorize?response_type=token&client_id=abc123",
      "https://passport.yandex.com/auth?retpath=https%3A%2F%2Foauth.yandex.com%2Fverification_code",
      "https://example.com/verification_code#access_token=stolen",
      "https://oauth.yandex.evil.example/verification_code#access_token=stolen",
      "http://oauth.yandex.com/verification_code#access_token=plain",
      "about:blank",
    ]
  )
  func elsewhere(address: String) {
    #expect(signIn.outcome(of: URL(string: address)!) == .elsewhere)
  }
}
