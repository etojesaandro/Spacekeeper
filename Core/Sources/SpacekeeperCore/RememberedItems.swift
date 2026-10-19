import Foundation

/// Library items remembered from an earlier reading, kept in a file.
///
/// Reading the size of every item takes the photo library tens of seconds,
/// while most items never change. Remembering them lets the next reading
/// ask the library only about what is new or changed.
public struct RememberedItems: Sendable {
  private let file: URL

  /// - Parameter file: Where the items are kept; it need not exist yet.
  public init(file: URL) {
    self.file = file
  }

  /// The items kept last time, by identifier; none when nothing readable is kept.
  public func items() -> [String: MediaItem] {
    guard
      let data = try? Data(contentsOf: file),
      let list = try? JSONDecoder().decode([MediaItem].self, from: data)
    else {
      return [:]
    }
    return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// Keeps the items, replacing those kept before.
  public func keep(_ items: [MediaItem]) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try JSONEncoder().encode(items).write(to: file, options: .atomic)
  }
}
