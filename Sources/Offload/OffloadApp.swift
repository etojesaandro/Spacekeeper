import SwiftUI
import TipKit

@main
struct OffloadApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  init() {
    // Hints show once each; failing to set them up only leaves them out.
    try? Tips.configure()
  }

  var body: some Scene {
    WindowGroup {
      RootView(
        survey: delegate.survey,
        uploads: delegate.uploads,
        kept: delegate.kept,
        cable: delegate.cable,
        clouds: delegate.clouds,
        yandex: delegate.yandex,
        google: delegate.google
      )
    }
  }
}
