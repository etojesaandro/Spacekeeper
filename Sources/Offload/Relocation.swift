import Foundation
import Observation
import OffloadCore

/// The move of one library item to Yandex Disk, as the screen follows it.
@MainActor
@Observable
final class Relocation {
  /// Where the move stands.
  enum Stage {
    case idle
    case working(String)
    case finished(String)
    case failed(String)
  }

  private(set) var stage = Stage.idle
  private let token: KeychainToken
  private let session: URLSession

  /// - Parameters:
  ///   - token: Where the Yandex Disk token is kept.
  ///   - session: Session the uploads go through.
  init(token: KeychainToken, session: URLSession) {
    self.token = token
    self.session = session
  }

  /// Uploads the item, verifies the copy and removes the original.
  ///
  /// - Returns: True when the item has left the photo library.
  func run(_ item: LibraryItem) async -> Bool {
    stage = .working("Preparing")
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("offload-\(UUID().uuidString)")
    defer {
      try? FileManager.default.removeItem(at: folder)
    }
    let say: @Sendable (String) -> Void = { text in
      Task { @MainActor in
        self.noted(text)
      }
    }
    let wire = PatientWire(session: session) { sent, total in
      say(
        sent < total
          ? "Uploading: \(sent.formatted(.byteCount(style: .file))) of "
            + "\(total.formatted(.byteCount(style: .file)))"
          : "Sent. Waiting for Yandex Disk to confirm"
      )
    }
    let vigil = Vigil()
    vigil.begin()
    defer {
      vigil.end()
    }
    do {
      let api = YandexApi(token: try token.value(), wire: wire)
      try await Offload(
        of: NarratedOriginal(PhotoOriginal(id: item.id, folder: folder), say: say),
        to: NarratedCloud(WithinAllowance(YandexDisk(api: api), api: api), say: say)
      ).run()
      stage = .finished(
        "\(item.name) is on Yandex Disk and in Recently Deleted on this iPhone. "
          + "Its space is freed once Recently Deleted is emptied."
      )
      return true
    } catch {
      stage = .failed(error.localizedDescription)
      return false
    }
  }

  /// Puts the result away once the user has read it.
  func acknowledge() {
    stage = .idle
  }

  private func noted(_ text: String) {
    // A late note must not replace the result.
    if case .working = stage {
      stage = .working(text)
    }
  }
}
