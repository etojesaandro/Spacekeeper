import OffloadCore
import SwiftUI

/// The backup to a computer over the cable: what to do, and how it is going.
struct CableView: View {
  private let cable: CableBackup
  private let close: () -> Void

  /// - Parameters:
  ///   - cable: The backup to show.
  ///   - close: Called when the user is done.
  init(cable: CableBackup, close: @escaping () -> Void) {
    self.cable = cable
    self.close = close
  }

  var body: some View {
    List {
      Section {
        Label("Connect this iPhone to the computer with a cable.", systemImage: "cable.connector")
        VStack(alignment: .leading, spacing: 6) {
          Label("On the computer, run:", systemImage: "terminal")
          Text("offload-backup ~/Pictures/iPhone")
            .font(.callout.monospaced())
            .textSelection(.enabled)
        }
        VStack(alignment: .leading, spacing: 6) {
          Label("Give it this code:", systemImage: "key")
          Text(cable.code.isEmpty ? "––––––" : spaced(cable.code))
            .font(.largeTitle.monospacedDigit().weight(.semibold))
        }
      } footer: {
        Text(
          "The computer gets copies; nothing leaves this iPhone. Keep this screen open "
            + "while the backup runs. Closing it ends the computer's access."
        )
      }
      Section("Progress") {
        LabeledContent("Files sent", value: cable.files.formatted())
        LabeledContent("Size sent", value: cable.bytes.formatted(.byteCount(style: .file)))
        LabeledContent("Items the computer holds", value: cable.held.count.formatted())
      }
      if !cable.held.isEmpty {
        Section {
          Button("Delete these \(cable.held.count) items from this iPhone", role: .destructive) {
            Task {
              await cable.free()
            }
          }
        } footer: {
          Text(
            "\(cable.held.reduce(0) { $0 + $1.bytes() }.formatted(.byteCount(style: .file))) "
              + "would be freed. The computer has checked every file it holds. To keep "
              + "them here as well, just close this screen. iOS asks you to confirm."
          )
        }
      }
      if !cable.note.isEmpty {
        Section {
          Text(cable.note)
            .font(.callout)
        }
      }
    }
    .navigationTitle("Back up to a computer")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") {
          close()
        }
      }
    }
    .onAppear {
      cable.open()
    }
    .onDisappear {
      cable.close()
    }
  }

  /// The code in two groups of three, as it is easier to read out.
  private func spaced(_ code: String) -> String {
    "\(code.prefix(3)) \(code.dropFirst(3))"
  }
}
