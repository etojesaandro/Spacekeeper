import Foundation

/// The place the files of one original take in the cloud.
///
/// Files are kept in a folder for the year and, inside it, one for the
/// month the original was made. The name starts with the moment itself, so
/// a folder lists in the order things happened, and carries a piece of the
/// library's identifier, so two originals of the same second do not collide.
public struct Placement: Sendable {
  private let taken: Date
  private let id: String
  private let zone: TimeZone

  /// - Parameters:
  ///   - taken: When the original was made; the distant past stands for unknown.
  ///   - id: The library's identifier of the original.
  ///   - zone: The time zone the moment is written in.
  public init(taken: Date, id: String, zone: TimeZone) {
    self.taken = taken
    self.id = id
    self.zone = zone
  }

  /// The paths of an original's files, in their order.
  ///
  /// Two files of one original may share a name; the later one is then
  /// told apart by its position among the files.
  public func paths(for filenames: [String]) -> [String] {
    var taken: Set<String> = []
    return filenames.enumerated().map { index, filename in
      let plain = path(for: filename)
      let path = taken.contains(plain) ? self.path(for: filename, marked: "\(index)") : plain
      taken.insert(path)
      return path
    }
  }

  /// The path, below the cloud's folder, of the file with the given name.
  public func path(for filename: String) -> String {
    path(for: filename, marked: "")
  }

  /// The same for a file that shares its name with another file of the original.
  public func path(for filename: String, marked mark: String) -> String {
    let tail = "\(id.prefix(8))_\(mark.isEmpty ? "" : "\(mark)_")\(filename)"
    guard taken != .distantPast else {
      return "undated/undated_\(tail)"
    }
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = zone
    format.dateFormat = "yyyy/MM/yyyy-MM-dd_HH-mm-ss"
    return "\(format.string(from: taken))_\(tail)"
  }
}
