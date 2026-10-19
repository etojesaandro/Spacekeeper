import Foundation

/// One original as an archive keeps it: one file, or several that belong together.
public struct KeptOriginal: Sendable, Equatable, Identifiable {
  private let files: [KeptFile]

  /// - Parameter files: Its files; there must be at least one.
  init(files: [KeptFile]) {
    self.files = files
  }

  /// Lists require a readable `id`.
  public var id: String {
    files.first?.id ?? ""
  }

  /// The name it had in the photo library.
  public func name() -> String {
    KeptName(leading().name()).original()
  }

  /// Bytes of all its files.
  public func bytes() -> Int64 {
    files.reduce(0) { $0 + $1.bytes }
  }

  /// How many files it is kept as.
  public func count() -> Int {
    files.count
  }

  /// Whether it is a video rather than a photo.
  public func video() -> Bool {
    parts().first?.role == .video
  }

  /// When it was made: as the cloud has it noted, else as its name says in
  /// the given time zone; empty when neither tells.
  public func made(in zone: TimeZone) -> [Date] {
    let noted = noted()
    return noted.isEmpty ? KeptName(leading().name()).moment(in: zone) : noted
  }

  /// When it was made, only if the cloud has the exact moment noted.
  public func noted() -> [Date] {
    leading().made
  }

  /// The file that shows what it is: the photo or video itself.
  public func leading() -> KeptFile {
    parts().first?.file ?? files[0]
  }

  /// The files a photo library takes back, each with the part it plays.
  ///
  /// The photo or video itself comes first. A clip beside a photo is the
  /// moving half of a Live Photo, a second picture is its other format.
  /// The rendered result of an edit and the edit's recipe are left out: a
  /// library cannot be handed them, so the original comes back unedited.
  public func parts() -> [KeptPart] {
    let wanted = files.filter { file in
      let name = KeptName(file.name()).original().lowercased()
      return !name.hasPrefix("fullsizerender") && !name.hasSuffix(".plist")
        && !name.hasSuffix(".aae")
    }
    let pictures = wanted.filter { Self.pictures.contains(suffix(of: $0)) }
      .sorted { !Self.raw.contains(suffix(of: $0)) && Self.raw.contains(suffix(of: $1)) }
    let clips = wanted.filter { Self.clips.contains(suffix(of: $0)) }
    guard let picture = pictures.first else {
      return clips.prefix(1).map { KeptPart(role: .video, file: $0) }
    }
    return [KeptPart(role: .photo, file: picture)]
      + pictures.dropFirst().prefix(1).map { KeptPart(role: .alternatePhoto, file: $0) }
      + clips.prefix(1).map { KeptPart(role: .pairedVideo, file: $0) }
  }

  private func suffix(of file: KeptFile) -> String {
    URL(fileURLWithPath: file.name()).pathExtension.lowercased()
  }

  private static let raw: Set<String> = ["dng", "raw", "cr2", "cr3", "nef", "arw", "raf", "orf"]
  private static let pictures: Set<String> =
    raw.union(["jpg", "jpeg", "heic", "heif", "png", "gif", "webp", "tif", "tiff", "bmp"])
  private static let clips: Set<String> = ["mov", "mp4", "m4v", "avi", "3gp"]
}

/// One file of a kept original together with the part it plays in a photo library.
public struct KeptPart: Sendable, Equatable {
  public let role: Role
  public let file: KeptFile

  /// The name the file had in the photo library.
  public func name() -> String {
    KeptName(file.name()).original()
  }
}

/// The part a file plays in a photo library item.
public enum Role: Sendable, Equatable {
  /// The picture of a photo.
  case photo

  /// The same picture in another format, such as RAW beside JPEG.
  case alternatePhoto

  /// The clip of a video.
  case video

  /// The moving half of a Live Photo.
  case pairedVideo
}
