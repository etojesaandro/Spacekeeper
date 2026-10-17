import OffloadCore
import SwiftUI

/// What is on its way to the cloud, and what the user can do about it.
///
/// It stays at the bottom of the screen for as long as anything is being
/// uploaded, waits to be deleted or could not be uploaded.
struct QueueBar: View {
  private let uploads: Uploads
  @ViewState private var explaining = false
  @ViewState private var stopping = false

  /// - Parameter uploads: The move to show.
  init(uploads: Uploads) {
    self.uploads = uploads
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if !uploads.travelling().isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ProgressView(
            value: Double(min(uploads.gone(), uploads.bytes())),
            total: Double(max(uploads.bytes(), 1))
          ) {
            HStack {
              Text(
                "Uploading \(uploads.travelling().count) · "
                  + "\(size(uploads.gone())) of \(size(uploads.bytes()))"
              )
              .font(.subheadline.weight(.semibold))
              .monospacedDigit()
              Spacer()
              Button("Cancel") {
                stopping = true
              }
              .font(.subheadline)
            }
          }
          Text("Uploads go on when you leave the app.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if !uploads.safe().isEmpty {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(
              "\(uploads.safe().count) on \(uploads.cloud()) · "
                + size(uploads.safe().reduce(0) { $0 + $1.bytes() })
            )
            .font(.subheadline.weight(.semibold))
            Button("Keep on this iPhone too") {
              Task {
                await uploads.keep()
              }
            }
            .font(.caption)
          }
          Spacer()
          Button("Delete from iPhone") {
            Task {
              await uploads.free()
            }
          }
          .buttonStyle(.borderedProminent)
        }
      }
      if !uploads.failed().isEmpty {
        HStack {
          Label("\(uploads.failed().count) not uploaded", systemImage: "exclamationmark.triangle")
            .font(.subheadline.weight(.semibold))
          Spacer()
          Button("Details") {
            explaining = true
          }
          .font(.subheadline)
        }
      }
    }
    .padding()
    .background(.bar)
    .confirmationDialog(
      "Cancel the uploads?",
      isPresented: $stopping,
      titleVisibility: .visible
    ) {
      Button("Cancel uploads", role: .destructive) {
        Task {
          await uploads.cancel()
        }
      }
    } message: {
      Text("Nothing is deleted from this iPhone.")
    }
    .alert("Not uploaded", isPresented: $explaining) {
      Button("Try again") {
        Task {
          await uploads.retry()
        }
      }
      Button("Leave on this iPhone", role: .destructive) {
        Task {
          await uploads.abandon()
        }
      }
      Button("Close", role: .cancel) {}
    } message: {
      Text(reasons)
    }
  }

  /// Why each failed item could not be uploaded, one paragraph each.
  private var reasons: String {
    uploads.failed().map { consignment in
      if case .failed(let reason) = consignment.standing() {
        return "\(consignment.original().name): \(reason)"
      }
      return consignment.original().name
    }
    .joined(separator: "\n\n")
  }

  private func size(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file))
  }
}
