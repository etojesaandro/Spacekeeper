import Foundation

/// The name a file travels under while it is uploaded to Yandex Disk.
///
/// The Disk slows uploads of videos, archives and data files, judging by
/// the extension, so such a file travels with a neutral extension added and
/// is renamed on arrival. Renaming costs two extra requests per file, which
/// matters for many small photos, and pictures are not slowed down. So
/// files with a known picture extension travel under their own name.
public struct Disguise: Sendable {
  private let suffix: String
  private let exempt: Set<String>

  /// - Parameters:
  ///   - suffix: Extension added to the name for the journey; empty for none.
  ///   - exempt: Lowercase extensions, without the dot, of files that keep their name.
  public init(suffix: String, exempt: Set<String>) {
    self.suffix = suffix
    self.exempt = exempt
  }

  /// Adds `.offload` to everything except common picture formats.
  ///
  /// Anything not on the list is disguised, because a needless rename only
  /// costs a second or two while a missed one can cost an hour.
  public init() {
    self.init(
      suffix: ".offload",
      exempt: ["jpg", "jpeg", "heic", "heif", "png", "gif", "webp", "tif", "tiff", "bmp"]
    )
  }

  /// Whether a name is one a file travels under, rather than its own.
  public func worn(by name: String) -> Bool {
    !suffix.isEmpty && name.hasSuffix(suffix)
  }

  /// The name the file with the given name travels under.
  public func name(for name: String) -> String {
    exempt.contains(URL(fileURLWithPath: name).pathExtension.lowercased()) ? name : name + suffix
  }
}
