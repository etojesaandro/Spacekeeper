import UIKit

/// A period in which the phone is kept from dozing off.
///
/// The screen stays on, and iOS is asked for the short extra time it grants
/// an app that has just been left, so a long upload is not cut by the
/// screen locking or by a brief trip to another app. iOS still stops the
/// app if it stays in the background longer than that.
@MainActor
final class Vigil {
  private var grace = UIBackgroundTaskIdentifier.invalid

  /// Starts keeping the phone awake.
  func begin() {
    UIApplication.shared.isIdleTimerDisabled = true
    grace = UIApplication.shared.beginBackgroundTask(withName: "Offload move") { [weak self] in
      // iOS ends an app that still holds the extra time when it runs out.
      self?.end()
    }
  }

  /// Lets the phone doze again.
  func end() {
    UIApplication.shared.isIdleTimerDisabled = false
    guard grace != .invalid else {
      return
    }
    UIApplication.shared.endBackgroundTask(grace)
    grace = .invalid
  }
}
