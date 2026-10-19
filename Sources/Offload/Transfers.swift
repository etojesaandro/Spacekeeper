import OffloadCore
import SwiftUI

/// A slim line above the tabs while anything is on its way, waits, or went wrong.
///
/// It never covers what the user is doing; a tap opens the details.
struct TransferStrip: View {
  private let uploads: Uploads
  private let open: () -> Void

  /// - Parameters:
  ///   - uploads: The move of items to the cloud.
  ///   - open: Shows the details.
  init(uploads: Uploads, open: @escaping () -> Void) {
    self.uploads = uploads
    self.open = open
  }

  var body: some View {
    if shows {
      Button(action: open) {
        HStack(spacing: 12) {
          symbol
            .frame(width: 28, height: 28)
          VStack(alignment: .leading, spacing: 1) {
            Text(headline)
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
              .truncationMode(.middle)
            Text(detail)
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 0)
          if !uploads.safe().isEmpty, uploads.travelling().isEmpty {
            Text("Free up")
              .font(.subheadline.weight(.semibold))
              .padding(.horizontal, 12)
              .padding(.vertical, 6)
              .background(Color.accentColor, in: Capsule())
              .foregroundStyle(.white)
          } else {
            Image(systemName: "chevron.up")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
      }
      .buttonStyle(.plain)
      .accessibilityHint("Shows the transfers")
    }
  }

  private var shows: Bool {
    if case .working = uploads.stage {
      return true
    }
    return !uploads.queue.isEmpty
  }

  @ViewBuilder private var symbol: some View {
    if case .working = uploads.stage {
      ProgressView()
    } else if !uploads.travelling().isEmpty {
      ProgressView(
        value: Double(min(uploads.gone(), uploads.bytes())),
        total: Double(max(uploads.bytes(), 1))
      )
      .progressViewStyle(Ring())
    } else if !uploads.failed().isEmpty {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    } else {
      Image(systemName: "checkmark.icloud.fill")
        .foregroundStyle(.green)
    }
  }

  private var headline: String {
    if case .working(let headline, _) = uploads.stage {
      return headline
    }
    if !uploads.travelling().isEmpty {
      return String(localized: "Uploading \(uploads.travelling().count) items to \(uploads.cloud())")
    }
    if !uploads.failed().isEmpty {
      return String(localized: "\(uploads.failed().count) items not uploaded")
    }
    return String(localized: "\(uploads.safe().count) items safe on \(uploads.cloud())")
  }

  private var detail: String {
    if case .working(_, let step) = uploads.stage {
      return step.isEmpty ? String(localized: "Getting ready") : step
    }
    if !uploads.travelling().isEmpty {
      return String(localized: "\(size(uploads.gone())) of \(size(uploads.bytes())) · goes on in the background")
    }
    if !uploads.failed().isEmpty {
      return String(localized: "Tap to see why and try again")
    }
    return String(localized: "Delete them here to free \(size(uploads.safe().reduce(0) { $0 + $1.bytes() }))")
  }

  private func size(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file))
  }
}

/// A small ring that fills as the uploads go.
private struct Ring: ProgressViewStyle {
  func makeBody(configuration: Configuration) -> some View {
    ZStack {
      Circle()
        .stroke(Color.secondary.opacity(0.25), lineWidth: 3)
      Circle()
        .trim(from: 0, to: configuration.fractionCompleted ?? 0)
        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(.linear, value: configuration.fractionCompleted)
    }
    .padding(3)
  }
}

/// Every item on its way, waiting to be deleted, or not uploaded, with what can be done.
struct TransfersSheet: View {
  private let uploads: Uploads
  @ViewState private var stopping = false
  @Environment(\.dismiss) private var dismiss

  init(uploads: Uploads) {
    self.uploads = uploads
  }

  var body: some View {
    NavigationStack {
      List {
        if !uploads.safe().isEmpty {
          Section {
            Button {
              Task {
                await uploads.free()
              }
            } label: {
              Label(
                "Delete from iPhone · free \(size(uploads.safe().reduce(0) { $0 + $1.bytes() }))",
                systemImage: "trash"
              )
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            Button("Keep them on this iPhone too") {
              Task {
                await uploads.keep()
              }
            }
            ForEach(uploads.safe(), id: \.id) { consignment in
              row(consignment, note: String(localized: "Checked on \(uploads.cloud())"), symbol: "checkmark.circle.fill", tint: .green)
            }
          } header: {
            Text("Safe on \(uploads.cloud())")
          } footer: {
            Text("Each copy was checked against the original. iOS asks before deleting.")
          }
        }
        if !uploads.travelling().isEmpty {
          Section {
            ForEach(uploads.travelling(), id: \.id) { consignment in
              row(
                consignment,
                note: String(localized: "\(size(consignment.gone(sent: uploads.sent))) of \(size(consignment.bytes()))"),
                symbol: "arrow.up.circle",
                tint: .accentColor
              )
            }
            Button("Cancel uploads", role: .destructive) {
              stopping = true
            }
          } header: {
            Text("Uploading")
          } footer: {
            Text("Uploads go on when you leave the app.")
          }
        }
        if !uploads.failed().isEmpty {
          Section {
            ForEach(uploads.failed(), id: \.id) { consignment in
              row(consignment, note: reason(consignment), symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
            Button("Try again") {
              Task {
                await uploads.retry()
              }
            }
            Button("Leave them on this iPhone", role: .destructive) {
              Task {
                await uploads.abandon()
              }
            }
          } header: {
            Text("Not uploaded")
          }
        }
        if uploads.queue.isEmpty {
          ContentUnavailableView(
            "Nothing on its way",
            systemImage: "checkmark.icloud",
            description: Text("Moves and copies show up here while they run.")
          )
          .listRowBackground(Color.clear)
        }
      }
      .navigationTitle("Transfers")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
      .confirmationDialog("Cancel the uploads?", isPresented: $stopping, titleVisibility: .visible) {
        Button("Cancel uploads", role: .destructive) {
          Task {
            await uploads.cancel()
          }
        }
      } message: {
        Text("Nothing is deleted from this iPhone.")
      }
    }
  }

  private func row(_ consignment: Consignment, note: String, symbol: String, tint: Color) -> some View {
    HStack(spacing: 12) {
      LibraryPicture(id: consignment.id, side: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      VStack(alignment: .leading, spacing: 2) {
        Text(consignment.original().name)
          .font(.subheadline)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(note)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
      Spacer(minLength: 0)
      Image(systemName: symbol)
        .foregroundStyle(tint)
    }
    .accessibilityElement(children: .combine)
  }

  private func reason(_ consignment: Consignment) -> String {
    if case .failed(let reason) = consignment.standing() {
      return reason
    }
    return String(localized: "Not uploaded")
  }

  private func size(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file))
  }
}

/// A short word at the top of the screen about something that finished or went wrong.
struct ResultBanner: View {
  let title: String
  let text: String
  let good: Bool
  let close: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
        .font(.title3)
        .foregroundStyle(good ? .green : .orange)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        if !text.isEmpty {
          Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.footnote.weight(.bold))
          .foregroundStyle(.secondary)
          .frame(width: 30, height: 30)
      }
      .accessibilityLabel("Dismiss")
    }
    .padding(14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    .padding(.horizontal, 12)
    .accessibilityElement(children: .combine)
    .task(id: title + text) {
      // A good outcome goes away by itself; a problem waits to be read.
      guard good else {
        return
      }
      try? await Task.sleep(for: .seconds(6))
      close()
    }
  }
}
