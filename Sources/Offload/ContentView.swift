import OffloadCore
import SwiftUI

/// The single screen of the app: the library survey, and moving items off the device.
struct ContentView: View {
  private let survey: Survey
  private let uploads: Uploads
  private let kept: Kept
  private let cable: CableBackup
  private let clouds: Clouds
  private let yandex: YandexAccount
  private let google: GoogleAccount
  @ViewState private var selecting = false
  @ViewState private var chosen: Set<String> = []
  @ViewState private var picked: [MediaItem] = []
  @ViewState private var viewed: [MediaItem] = []
  @ViewState private var asking = false
  @ViewState private var browsing = false
  @ViewState private var wiring = false
  @Environment(\.scenePhase) private var phase
  // The ClientID names the application to Yandex; it is public, not a secret.
  private let signIn = YandexSignIn(client: "3dc12ba965ba42bc81540825932299c0")

  /// - Parameters:
  ///   - survey: The library survey to show.
  ///   - uploads: The move of items to the chosen cloud.
  ///   - kept: What the chosen cloud keeps.
  ///   - cable: The backup to a computer over the cable.
  ///   - clouds: Which cloud is chosen, and who is signed in.
  ///   - yandex: The Yandex Disk account.
  ///   - google: The Google Drive account.
  init(
    survey: Survey,
    uploads: Uploads,
    kept: Kept,
    cable: CableBackup,
    clouds: Clouds,
    yandex: YandexAccount,
    google: GoogleAccount
  ) {
    self.survey = survey
    self.uploads = uploads
    self.kept = kept
    self.cable = cable
    self.clouds = clouds
    self.yandex = yandex
    self.google = google
  }

  var body: some View {
    NavigationStack {
      content
        .navigationTitle("Offload")
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button(selecting ? "Done" : "Select") {
              selecting.toggle()
              chosen = []
            }
          }
          ToolbarItem(placement: .topBarTrailing) {
            Menu("More", systemImage: "ellipsis.circle") {
              Button("On \(clouds.name)", systemImage: "icloud") {
                browsing = true
              }
              Button("Back up to a computer", systemImage: "desktopcomputer") {
                wiring = true
              }
              Button("Clouds and accounts", systemImage: "person.crop.circle") {
                asking = true
              }
              Button("Read the library again", systemImage: "arrow.clockwise") {
                Task {
                  await survey.afresh()
                }
              }
            }
          }
        }
        .safeAreaInset(edge: .bottom) {
          VStack(spacing: 0) {
            if selecting {
              Button {
                picked = marked
              } label: {
                Text(
                  marked.isEmpty
                    ? "Nothing selected"
                    : "\(marked.count) selected · \(size(of: marked))"
                )
                .frame(maxWidth: .infinity)
              }
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .disabled(marked.isEmpty)
              .padding()
              .background(.bar)
            }
            if !uploads.queue.isEmpty {
              QueueBar(uploads: uploads)
            }
          }
        }
    }
    .disabled(working)
    .overlay {
      if case .working(let headline, let step) = uploads.stage {
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
      Task {
        await uploads.wake()
      }
    } content: {
      AccountSheet(
        clouds: clouds,
        yandex: yandex,
        google: google,
        signIn: signIn,
        busy: !uploads.queue.isEmpty
      )
    }
    .sheet(isPresented: $wiring) {
      NavigationStack {
        CableView(cable: cable) {
          wiring = false
        }
      }
    }
    .sheet(isPresented: $browsing) {
      NavigationStack {
        DiskView(kept: kept, cloud: clouds.name, path: "") {
          browsing = false
        }
      }
    }
    .sheet(isPresented: Binding(get: { !viewed.isEmpty }, set: { _ in viewed = [] })) {
      if let item = viewed.first {
        Closeup(
          item: item,
          cloud: clouds.name,
          away: uploads.queue.contains { $0.id == item.id }
        ) { deed in
          carry(out: deed, on: [item])
        }
      }
    }
    .confirmationDialog(
      picked.count == 1 ? picked[0].name : "\(picked.count) items · \(size(of: picked))",
      isPresented: Binding(get: { !picked.isEmpty }, set: { _ in picked = [] }),
      titleVisibility: .visible,
      presenting: picked.isEmpty ? nil : picked
    ) { items in
      Button("Move to \(clouds.name)") {
        carry(out: .move, on: items)
      }
      Button("Copy to \(clouds.name)") {
        carry(out: .copy, on: items)
      }
      Button("Delete only", role: .destructive) {
        carry(out: .delete, on: items)
      }
    } message: { _ in
      Text(
        "Move uploads, checks that \(clouds.name) has identical copies, then deletes here. "
          + "Copy uploads and keeps them here. Delete only removes them from this iPhone "
          + "without a copy. iOS asks you to confirm every deletion."
      )
    }
    .alert(
      outcome.title,
      isPresented: Binding(get: { !outcome.title.isEmpty }, set: { _ in uploads.acknowledge() })
    ) {
      Button("OK") {}
    } message: {
      Text(outcome.text)
    }
    .task {
      await survey.run()
    }
    .task(id: watching) {
      // The Disk may take a while to show a file, and a lost connection comes back.
      guard watching else {
        return
      }
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(20))
        await uploads.tick()
      }
    }
    .onChange(of: phase) { _, now in
      if now == .active {
        Task {
          await uploads.wake()
        }
      }
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
      RankingView(
        findings: findings,
        selecting: selecting,
        chosen: $chosen,
        away: Set(uploads.queue.map { $0.id })
      ) { period, order in
        survey.arrange(for: period, by: order)
      } pick: { item in
        viewed = [item]
      }
    }
  }

  private func carry(out deed: Deed, on items: [MediaItem]) {
    Task {
      selecting = false
      chosen = []
      switch deed {
      case .move:
        await uploads.begin(items, aim: .move)
      case .copy:
        await uploads.begin(items, aim: .copy)
      case .delete:
        await uploads.delete(items)
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
    if case .working = uploads.stage {
      return true
    }
    return false
  }

  /// Whether something is travelling while the app is in front.
  private var watching: Bool {
    phase == .active && !uploads.travelling().isEmpty
  }

  /// Title and text of the alert that closes a move; an empty title means no alert.
  private var outcome: (title: String, text: String) {
    if case .done(let title, let text) = uploads.stage {
      return (title, text)
    }
    return ("", "")
  }

  private func size(of items: [MediaItem]) -> String {
    items.reduce(0) { $0 + $1.bytes() }.formatted(.byteCount(style: .file))
  }
}
