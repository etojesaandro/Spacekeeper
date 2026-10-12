import OffloadCore
import SwiftUI
import WebKit

/// Yandex's sign-in page, shown inside the app.
///
/// Yandex returns the token to an address of its own, which the system
/// sign-in sheet cannot hand back to an app. So the page is shown in a web
/// view and every address it goes to is checked for the token.
struct YandexPage: UIViewRepresentable {
  private let signIn: YandexSignIn
  private let done: (YandexSignIn.Outcome) -> Void

  /// - Parameters:
  ///   - signIn: The sign-in to carry out.
  ///   - done: Told once how the sign-in ended.
  init(signIn: YandexSignIn, done: @escaping (YandexSignIn.Outcome) -> Void) {
    self.signIn = signIn
    self.done = done
  }

  func makeCoordinator() -> Watch {
    Watch(signIn: signIn, done: done)
  }

  func makeUIView(context: Context) -> WKWebView {
    let view = WKWebView(frame: .zero)
    view.navigationDelegate = context.coordinator
    view.load(URLRequest(url: signIn.page()))
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {}

  /// Watches where the page goes and stops it at Yandex's return address.
  @MainActor
  final class Watch: NSObject, WKNavigationDelegate {
    private let signIn: YandexSignIn
    private let done: (YandexSignIn.Outcome) -> Void
    private var ended = false

    init(signIn: YandexSignIn, done: @escaping (YandexSignIn.Outcome) -> Void) {
      self.signIn = signIn
      self.done = done
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor action: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
      guard let address = action.request.url, seen(address) else {
        return .allow
      }
      return .cancel
    }

    // The return address may also be reached without a navigation of its own.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
      if let address = webView.url {
        _ = seen(address)
      }
    }

    /// Whether the address ended the sign-in.
    private func seen(_ address: URL) -> Bool {
      let outcome = signIn.outcome(of: address)
      guard outcome != .elsewhere else {
        return false
      }
      if !ended {
        ended = true
        done(outcome)
      }
      return true
    }
  }
}
