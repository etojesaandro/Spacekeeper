import SwiftUI

/// A form for entering the Yandex Disk token by hand.
///
/// This stands in for a sign-in screen while the app is a proof of concept.
struct TokenSheet: View {
  private let token: KeychainToken
  @ViewState private var text = ""
  @ViewState private var problem = ""
  @Environment(\.dismiss) private var dismiss

  init(token: KeychainToken) {
    self.token = token
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SecureField("Token", text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } footer: {
          Text(
            problem.isEmpty
              ? "Paste the token Yandex OAuth issued for your app. It is kept in the keychain."
              : problem
          )
        }
      }
      .navigationTitle("Yandex Disk")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            do {
              try token.keep(text.trimmingCharacters(in: .whitespacesAndNewlines))
              dismiss()
            } catch {
              problem = error.localizedDescription
            }
          }
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
  }
}
