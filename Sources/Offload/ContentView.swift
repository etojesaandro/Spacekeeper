import SwiftUI

/// The single screen of the app: the library survey, and moving items off the device.
struct ContentView: View {
  @ViewState private var survey: Survey
  @ViewState private var relocation: Relocation
  @ViewState private var picked: [LibraryItem] = []
  @ViewState private var asking = false
  private let token: KeychainToken

  init() {
    let token = KeychainToken(service: "Offload.YandexDisk")
    self.token = token
    _survey = ViewState(initialValue: Survey(photos: DevicePhotos()))
    // A large upload may sit silent for minutes while the Disk files it away.
    let patient = URLSessionConfiguration.default
    patient.timeoutIntervalForRequest = 600
    patient.timeoutIntervalForResource = 6 * 3600
    patient.waitsForConnectivity = true
    _relocation = ViewState(
      initialValue: Relocation(token: token, session: URLSession(configuration: patient))
    )
  }

  var body: some View {
    NavigationStack {
      content
        .navigationTitle("Biggest first")
        .toolbar {
          Button("Yandex Disk token", systemImage: "key") {
            asking = true
          }
          Button("Read again", systemImage: "arrow.clockwise") {
            Task {
              await survey.run()
            }
          }
        }
    }
    .disabled(working)
    .overlay {
      if case .working(let step) = relocation.stage {
        VStack(spacing: 12) {
          ProgressView()
          Text(step)
            .font(.footnote)
            .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: 280)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
      }
    }
    .sheet(isPresented: $asking) {
      TokenSheet(token: token)
    }
    .confirmationDialog(
      "Move to Yandex Disk?",
      isPresented: Binding(get: { !picked.isEmpty }, set: { _ in picked = [] }),
      titleVisibility: .visible,
      presenting: picked.first
    ) { item in
      Button("Upload, verify, then delete") {
        Task {
          if await relocation.run(item) {
            survey.forget(item)
          }
        }
      }
    } message: { item in
      Text(
        "\(item.name), \(item.bytes().formatted(.byteCount(style: .file))). "
          + "It is deleted from this iPhone only after Yandex Disk confirms an identical copy, "
          + "and iOS will ask you to confirm the deletion."
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
      RankingView(findings: findings, shown: 100) { item in
        picked = [item]
      }
    }
  }

  private var working: Bool {
    if case .working = relocation.stage {
      return true
    }
    return false
  }

  /// Title and text of the alert that closes a move; an empty title means no alert.
  private var outcome: (title: String, text: String) {
    switch relocation.stage {
    case .finished(let text):
      return ("Moved", text)
    case .failed(let text):
      return ("Not moved, nothing was deleted", text)
    case .idle, .working:
      return ("", "")
    }
  }
}
