import OffloadCore
import SwiftUI

/// The app's screen: the Library, Cloud and Backup tabs, and what lies above them.
struct RootView: View {
  private let survey: Survey
  private let uploads: Uploads
  private let kept: Kept
  private let cable: CableBackup
  private let clouds: Clouds
  private let yandex: YandexAccount
  private let google: GoogleAccount
  @ViewState private var asking = false
  @ViewState private var watching = false
  @AppStorage("Offload.welcomed") private var welcomed = false
  @Environment(\.scenePhase) private var phase
  // The ClientID names the application to Yandex; it is public, not a secret.
  private let signIn = YandexSignIn(client: "3dc12ba965ba42bc81540825932299c0")

  /// - Parameters:
  ///   - survey: The library survey.
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
    TabView {
      LibraryTab(survey: survey, uploads: uploads, clouds: clouds, account: openAccount) { deed, items in
        carry(out: deed, on: items)
      }
      .safeAreaInset(edge: .bottom) {
        TransferStrip(uploads: uploads) {
          watching = true
        }
      }
      .tabItem {
        Label("Library", systemImage: "photo.on.rectangle")
      }
      CloudTab(kept: kept, clouds: clouds, account: openAccount)
        .safeAreaInset(edge: .bottom) {
          TransferStrip(uploads: uploads) {
            watching = true
          }
        }
        .tabItem {
          Label("Cloud", systemImage: "icloud")
        }
      BackupTab(cable: cable, clouds: clouds, account: openAccount)
        .tabItem {
          Label("Backup", systemImage: "desktopcomputer")
        }
    }
    .overlay(alignment: .top) {
      if let (title, text, good) = outcome {
        ResultBanner(title: title, text: text, good: good) {
          withAnimation {
            uploads.acknowledge()
          }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .animation(.snappy, value: outcome?.0)
    .sensoryFeedback(trigger: outcome?.0) { _, now in
      guard let now, let good = outcome?.2, !now.isEmpty else {
        return nil
      }
      return good ? .success : .warning
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
    .sheet(isPresented: $watching) {
      TransfersSheet(uploads: uploads)
        .presentationDetents([.medium, .large])
    }
    .fullScreenCover(isPresented: Binding(get: { !welcomed }, set: { _ in })) {
      Welcome(clouds: clouds) {
        welcomed = true
        Task {
          await survey.run()
        }
      } connect: {
        welcomed = true
        Task {
          await survey.run()
        }
        asking = true
      }
    }
    .task {
      // The first launch asks for Photos only once the welcome has said why.
      if welcomed {
        await survey.run()
      }
    }
    .task(id: busy) {
      // The cloud may take a while to show a file, and a lost connection comes back.
      guard busy else {
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

  private func openAccount() {
    asking = true
  }

  private func carry(out deed: Deed, on items: [MediaItem]) {
    Task {
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

  /// Whether something is travelling while the app is in front.
  private var busy: Bool {
    phase == .active && !uploads.travelling().isEmpty
  }

  /// The banner to show: its title, its text, and whether the news is good.
  private var outcome: (String, String, Bool)? {
    switch uploads.stage {
    case .done(let title, let text):
      return (title, text, false)
    case .told(let title, let text):
      return (title, text, true)
    case .idle, .working:
      return nil
    }
  }
}

/// The first screen of the first launch: what the app does, and connecting a cloud.
struct Welcome: View {
  let clouds: Clouds
  let start: () -> Void
  let connect: () -> Void

  var body: some View {
    VStack(spacing: 28) {
      Spacer(minLength: 20)
      Image(systemName: "photo.stack")
        .font(.system(size: 64))
        .foregroundStyle(.tint)
        .symbolRenderingMode(.hierarchical)
      VStack(spacing: 8) {
        Text("Free up space,\nkeep every photo")
          .font(.largeTitle.weight(.bold))
          .multilineTextAlignment(.center)
        Text("Offload shows what takes the most room and keeps the originals safe elsewhere.")
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      VStack(alignment: .leading, spacing: 20) {
        Point(symbol: "arrow.down.circle", title: "Biggest first",
              text: "Every photo and video with its size, the largest at the top.")
        Point(symbol: "checkmark.icloud", title: "Checked before deleting",
              text: "A copy on Yandex Disk or Google Drive is compared with the original first.")
        Point(symbol: "desktopcomputer", title: "Or back up to a computer",
              text: "Over the cable, to Windows, macOS or Linux, in folders by year and month.")
      }
      .padding(.horizontal, 8)
      Spacer(minLength: 20)
      VStack(spacing: 12) {
        Button(action: connect) {
          Text("Connect a Cloud")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        Button("Not Now", action: start)
          .font(.headline)
      }
      .controlSize(.large)
      Text("Offload asks to see your photos next. It reads them on this iPhone only.")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(24)
    .frame(maxWidth: 520)
  }
}

/// One point of the welcome: a symbol, a short title, a line.
private struct Point: View {
  let symbol: String
  let title: LocalizedStringKey
  let text: LocalizedStringKey

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      Image(systemName: symbol)
        .font(.title2)
        .foregroundStyle(.tint)
        .frame(width: 34)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        Text(text)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
