import SwiftUI

@main
struct OffloadApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  var body: some Scene {
    WindowGroup {
      ContentView(
        survey: delegate.survey,
        uploads: delegate.uploads,
        kept: delegate.kept,
        token: delegate.token
      )
    }
  }
}
