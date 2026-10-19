import OffloadCore
import SwiftUI

/// The Backup tab: copying the library to a computer through the cable.
///
/// The computer can reach the library only while this tab is on screen,
/// and only with the code it shows.
struct BackupTab: View {
  private let cable: CableBackup
  private let clouds: Clouds
  private let account: () -> Void

  /// - Parameters:
  ///   - cable: The backup to a computer over the cable.
  ///   - clouds: Which cloud is chosen, for the account button.
  ///   - account: Opens the clouds and accounts.
  init(cable: CableBackup, clouds: Clouds, account: @escaping () -> Void) {
    self.cable = cable
    self.clouds = clouds
    self.account = account
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(spacing: 6) {
            Text("Code for the computer")
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Text(cable.code.isEmpty ? "––– –––" : spaced(cable.code))
              .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
              .textSelection(.enabled)
              .accessibilityLabel(cable.code.map(String.init).joined(separator: " "))
            Text("Keep this screen open while the backup runs.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
        }
        Section("How it works") {
          Step(number: 1, title: "Connect this iPhone to the computer with a cable") {
            Text("Unlock the iPhone and tap Trust if it asks.")
          }
          Step(number: 2, title: "Start offload-backup on the computer") {
            Text("Windows, macOS and Linux. On Windows a double click is enough.")
          }
          Step(number: 3, title: "Type the code shown above") {
            Text("Files go into Pictures/iPhone, in folders by year and month. Running it again fetches only what is new.")
          }
        }
        if cable.files > 0 || !cable.held.isEmpty {
          Section("This backup") {
            LabeledContent("Files sent", value: cable.files.formatted())
            LabeledContent("Size sent", value: cable.bytes.formatted(.byteCount(style: .file)))
            LabeledContent("Items the computer holds", value: cable.held.count.formatted())
          }
        }
        if !cable.held.isEmpty {
          Section {
            Button(role: .destructive) {
              Task {
                await cable.free()
              }
            } label: {
              Label(
                String(
                  localized: "Delete \(cable.held.count) items from iPhone · free \(cable.held.reduce(0) { $0 + $1.bytes() }.formatted(.byteCount(style: .file)))"
                ),
                systemImage: "trash"
              )
            }
          } footer: {
            Text("The computer checked every file it holds. To keep them here as well, do nothing.")
          }
        }
        if !cable.note.isEmpty {
          Section {
            Label(cable.note, systemImage: "info.circle")
              .font(.callout)
          }
        }
      }
      .navigationTitle("Backup")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          AccountButton(clouds: clouds, open: account)
        }
      }
      .onAppear {
        cable.open()
      }
      .onDisappear {
        cable.close()
      }
    }
  }

  /// The code in two groups of three, as it is easier to read out.
  private func spaced(_ code: String) -> String {
    "\(code.prefix(3)) \(code.dropFirst(3))"
  }
}

/// One numbered step of the instructions.
private struct Step<Detail: View>: View {
  let number: Int
  let title: LocalizedStringKey
  @ViewBuilder let detail: Detail

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Text(verbatim: number.formatted())
        .font(.subheadline.weight(.bold))
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .background(Color.accentColor, in: Circle())
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        detail
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
    .accessibilityElement(children: .combine)
  }
}
