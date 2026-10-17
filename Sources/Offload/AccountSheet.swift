import AuthenticationServices
import OffloadCore
import SwiftUI
import WebKit
// The cross-import that gives SwiftUI its web sign-in is not made by this build on its own.
import _AuthenticationServices_SwiftUI

/// The clouds: which one originals go to, and signing in to or out of each.
struct AccountSheet: View {
  private let clouds: Clouds
  private let yandex: YandexAccount
  private let google: GoogleAccount
  private let signIn: YandexSignIn
  private let busy: Bool
  @ViewState private var connected: Set<String>
  @ViewState private var problem = ""
  @ViewState private var working = false
  @ViewState private var askingYandex = false
  @Environment(\.webAuthenticationSession) private var web
  @Environment(\.dismiss) private var dismiss

  /// - Parameters:
  ///   - clouds: The clouds as the screen follows them.
  ///   - yandex: The Yandex Disk account.
  ///   - google: The Google Drive account.
  ///   - signIn: Yandex's sign-in page.
  ///   - busy: Whether uploads are waiting, which keeps the chosen cloud from changing.
  init(
    clouds: Clouds,
    yandex: YandexAccount,
    google: GoogleAccount,
    signIn: YandexSignIn,
    busy: Bool
  ) {
    self.clouds = clouds
    self.yandex = yandex
    self.google = google
    self.signIn = signIn
    self.busy = busy
    _connected = ViewState(
      initialValue: Set(clouds.all().filter { $0.signedIn() }.map { $0.key() })
    )
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          ForEach(clouds.all().indices, id: \.self) { index in
            let account = clouds.all()[index]
            Button {
              clouds.choose(account)
            } label: {
              HStack {
                Text(account.name())
                  .foregroundStyle(.primary)
                Spacer()
                if account.key() == clouds.chosen().key() {
                  Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                }
              }
            }
            .disabled(busy)
          }
        } header: {
          Text("Keep originals in")
        } footer: {
          Text(
            busy
              ? "The cloud can be changed once nothing is waiting to upload."
              : "Move, Copy and the cloud's browser use the cloud chosen here."
          )
        }
        Section(yandex.name()) {
          if connected.contains(yandex.key()) {
            Label("Signed in", systemImage: "checkmark.icloud")
            Button("Sign out", role: .destructive) {
              Task {
                await leaveYandex()
              }
            }
          } else {
            Button("Sign in to Yandex") {
              problem = ""
              askingYandex = true
            }
          }
        }
        Section {
          if connected.contains(google.key()) {
            Label("Signed in", systemImage: "checkmark.icloud")
            Button("Sign out", role: .destructive) {
              Task {
                await leaveGoogle()
              }
            }
          } else {
            Button("Sign in with Google") {
              Task {
                await joinGoogle()
              }
            }
            .disabled(working)
          }
        } header: {
          Text(google.name())
        } footer: {
          Text("Offload sees only the files it puts in the Offload folder of your Drive.")
        }
        if !problem.isEmpty {
          Section {
            Label(problem, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Clouds")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(isPresented: $askingYandex) {
        YandexPage(signIn: signIn) { outcome in
          arrived(outcome)
        }
        .navigationTitle("Yandex Disk")
      }
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
        try yandex.keep(secret)
      } catch {
        problem = error.localizedDescription
      }
      askingYandex = false
    case .refused(let reason):
      problem = reason
      askingYandex = false
    case .elsewhere:
      break
    }
    noticed()
  }

  /// Forgets the token and Yandex's cookies, so another account can sign in.
  private func leaveYandex() async {
    await yandex.signOut()
    await WKWebsiteDataStore.default().removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
      modifiedSince: .distantPast
    )
    noticed()
  }

  /// Signs in on Google's own page, in the system's browser sheet.
  ///
  /// Google refuses sign-ins inside an app's own web view, unlike Yandex.
  private func joinGoogle() async {
    problem = ""
    working = true
    defer {
      working = false
    }
    let attempt = google.signIn()
    do {
      let back = try await web.authenticate(
        using: attempt.page(),
        callbackURLScheme: attempt.scheme(),
        preferredBrowserSession: .shared
      )
      switch attempt.outcome(of: back) {
      case .granted(let code):
        try await google.keep(code, from: attempt)
      case .refused(let reason):
        problem = reason
      case .elsewhere:
        problem = "Google returned to an unexpected address"
      }
    } catch ASWebAuthenticationSessionError.canceledLogin {
      // The user closed the sheet; nothing to tell.
    } catch {
      problem = error.localizedDescription
    }
    noticed()
  }

  private func leaveGoogle() async {
    await google.signOut()
    noticed()
  }

  private func noticed() {
    connected = Set(clouds.all().filter { $0.signedIn() }.map { $0.key() })
    clouds.noticed()
  }
}
