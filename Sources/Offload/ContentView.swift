import OffloadCore
import SwiftUI

/// The single screen of the app: the library survey, and moving items off the device.
struct ContentView: View {
  @ViewState private var survey: Survey
  @ViewState private var relocation: Relocation
  @ViewState private var selecting = false
  @ViewState private var chosen: Set<String> = []
  @ViewState private var picked: [MediaItem] = []
  @ViewState private var asking = false
  private let token: KeychainToken

  init() {
    let token = KeychainToken(service: "Offload.YandexDisk")
    self.token = token
    _survey = ViewState(
      initialValue: Survey(
        photos: DevicePhotos(),
        remembered: RememberedItems(
          file: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("library-items-v1.json")
        )
      )
    )
    // A large upload may sit silent for minutes while the Disk files it away.
    let patient = URLSessionConfiguration.default
    patient.timeoutIntervalForRequest = 600
    patient.timeoutIntervalForResource = 6 * 3600
    _relocation = ViewState(
      initialValue: Relocation(token: token, session: URLSession(configuration: patient))
    )
  }

  var body: some View {
    NavigationStack {
      content
        .navigationTitle("Biggest first")
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button(selecting ? "Done" : "Select") {
              selecting.toggle()
              chosen = []
            }
          }
          ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Yandex Disk token", systemImage: "key") {
              asking = true
            }
            Button("Read again", systemImage: "arrow.clockwise") {
              Task {
                await survey.afresh()
              }
            }
          }
        }
        .safeAreaInset(edge: .bottom) {
          if selecting {
            Button {
              picked = marked
            } label: {
              Text(
                marked.isEmpty
                  ? "Nothing selected"
                  : "Move \(marked.count) · \(size(of: marked))"
              )
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(marked.isEmpty)
            .padding()
            .background(.bar)
          }
        }
    }
    .disabled(working)
    .overlay {
      if case .working(let headline, let step) = relocation.stage {
        VStack(spacing: 12) {
          ProgressView()
          Text(headline)
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
            .truncationMode(.middle)
          Text(step)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
      }
    }
    .sheet(isPresented: $asking) {
      TokenSheet(token: token)
    }
    .confirmationDialog(
      picked.count == 1 ? "Move to Yandex Disk?" : "Move \(picked.count) items to Yandex Disk?",
      isPresented: Binding(get: { !picked.isEmpty }, set: { _ in picked = [] }),
      titleVisibility: .visible,
      presenting: picked.isEmpty ? nil : picked
    ) { items in
      Button("Upload, verify, then delete") {
        Task {
          survey.forget(await relocation.run(items))
          selecting = false
          chosen = []
        }
      }
    } message: { items in
      Text(
        "\(items.count == 1 ? items[0].name : "\(items.count) items"), \(size(of: items)). "
          + "Nothing is deleted from this iPhone until Yandex Disk confirms an identical copy, "
          + "and iOS will ask you once to confirm the deletion."
      )
    }
    .alert(
      outcome.title,
      isPresented: Binding(get: { !outcome.title.isEmpty }, set: { _ in relocation.acknowledge() })
    ) {
      Button("OK") {}
    } message: {
      Text(outcome.text)
    }
    .task {
      await survey.run()
    }
  }

  @ViewBuilder private var content: some View {
    switch survey.stage {
    case .waiting:
      ProgressView()
    case .refused:
      ContentUnavailableView(
        "No access to Photos",
        systemImage: "lock",
        description: Text("Allow access in Settings › Privacy & Security › Photos.")
      )
    case .reading(let done, let of):
      ProgressView(value: Double(done), total: Double(max(of, 1))) {
        Text("Reading sizes: \(done) of \(of)")
      }
      .padding()
    case .ranked(let findings):
      RankingView(findings: findings, shown: 100, selecting: selecting, chosen: $chosen) { item in
        picked = [item]
      }
    }
  }

  /// The items marked in selection, biggest first.
  private var marked: [MediaItem] {
    guard case .ranked(let findings) = survey.stage else {
      return []
    }
    return findings.items.filter { chosen.contains($0.id) }
  }

  private var working: Bool {
    if case .working = relocation.stage {
      return true
    }
    return false
  }

  /// Title and text of the alert that closes a move; an empty title means no alert.
  private var outcome: (title: String, text: String) {
    if case .done(let title, let text) = relocation.stage {
      return (title, text)
    }
    return ("", "")
  }

  private func size(of items: [MediaItem]) -> String {
    items.reduce(0) { $0 + $1.bytes() }.formatted(.byteCount(style: .file))
  }
}
