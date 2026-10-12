import Foundation
import OffloadCore
import UIKit
import os

/// The app as the system starts it, with or without a screen.
///
/// The system may start the app out of sight to tell it that uploads have
/// finished. So everything that follows the uploads is put together here,
/// rather than in a view that may never appear. UIKit creates this object
/// itself and takes no arguments, which is why it builds its own parts.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
  // The app's scene reads these four to hand them to its views.
  let token: KeychainToken
  let survey: Survey
  let uploads: Uploads
  let kept: Kept

  override init() {
    let token = KeychainToken(service: "Offload.YandexDisk")
    let survey = Survey(
      photos: DevicePhotos(),
      remembered: RememberedItems(
        file: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("library-items-v1.json")
      )
    )
    let home = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Outbox")
    let (news, voice) = AsyncStream<TransitNews>.makeStream()
    let background = URLSessionConfiguration.background(
      withIdentifier: "\(Bundle.main.bundleIdentifier ?? "Offload").uploads"
    )
    background.sessionSendsLaunchEvents = true
    background.isDiscretionary = false
    // The Disk goes silent for minutes after the last byte of a large file,
    // and a silence taken for a failure would send the whole file again.
    background.timeoutIntervalForRequest = 3600
    background.timeoutIntervalForResource = 2 * 24 * 3600
    let log = Logger(subsystem: "Offload", category: "outbox")
    let say: @Sendable (String) -> Void = { text in
      log.notice("\(text, privacy: .public)")
    }
    let (words, pen) = AsyncStream<String>.makeStream()
    self.token = token
    self.survey = survey
    self.kept = Kept(
      archive: SignedInDisk(
        token: token,
        wire: PatientWire(session: URLSession(configuration: .default)) { text in
          pen.yield(text)
        }
      ),
      gallery: PhotoGallery(),
      survey: survey,
      scratch: FileManager.default.temporaryDirectory.appendingPathComponent("Restore"),
      words: words
    )
    self.uploads = Uploads(
      outbox: Outbox(
        manifest: Manifest(file: home.appendingPathComponent("manifest.json")),
        store: home.appendingPathComponent("files"),
        depot: SignedInDisk(
          token: token,
          wire: PatientWire(session: URLSession(configuration: .default), say: { _ in })
        ),
        transit: SystemTransit(
          session: URLSession(
            configuration: background,
            delegate: TransitEars(news: voice),
            delegateQueue: nil
          )
        ),
        patience: Patience(tries: 15, pause: .seconds(2)),
        abreast: 8,
        sends: 3,
        say: say
      ),
      staging: Staging(store: home.appendingPathComponent("files")),
      bin: PhotoBin(),
      token: token,
      survey: survey,
      news: news
    )
    super.init()
  }

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    uploads.start()
    kept.start()
    return true
  }

  func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    uploads.woken(completionHandler)
  }
}
