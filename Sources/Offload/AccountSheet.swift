import OffloadCore
import SwiftUI
import WebKit

/// The Yandex Disk account: signing in when there is none, signing out when there is one.
struct AccountSheet: View {
  private let token: KeychainToken
  private let signIn: YandexSignIn
  @ViewState private var connected: Bool
  @ViewState private var problem = ""
  @Environment(\.dismiss) private var dismiss

  init(token: KeychainToken, signIn: YandexSignIn) {
    self.token = token
    self.signIn = signIn
    _connected = ViewState(initialValue: (try? token.value()) != nil)
  }

  var body: some View {
    NavigationStack {
      Group {
        if connected {
          ContentUnavailableView {
            Label("Connected to Yandex Disk", systemImage: "checkmark.icloud")
          } description: {
            Text("Files go to this app's own folder on your Disk.")
          } actions: {
            Button("Sign out", role: .destructive) {
              leave()
            }
          }
        } else if !problem.isEmpty {
          ContentUnavailableView {
            Label("Not signed in", systemImage: "xmark.icloud")
          } description: {
            Text(problem)
          } actions: {
            Button("Try again") {
              problem = ""
            }
          }
        } else {
          YandexPage(signIn: signIn) { outcome in
            arrived(outcome)
          }
        }
      }
      .navigationTitle("Yandex Disk")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
  }

  private func arrived(_ outcome: YandexSignIn.Outcome) {
    switch outcome {
    case .granted(let secret):
      do {
        try token.keep(secret)
        connected = true
      } catch {
        problem = error.localizedDescription
      }
    case .refused(let reason):
      problem = reason
    case .elsewhere:
      break
    }
  }

  /// Forgets the token and Yandex's cookies, so another account can sign in.
  private func leave() {
    token.forget()
    WKWebsiteDataStore.default().removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
      modifiedSince: .distantPast
    ) {}
    connected = false
  }
}
