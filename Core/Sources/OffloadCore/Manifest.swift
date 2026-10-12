import Foundation

/// The list of consignments on their way, kept in a file.
///
/// It is read anew for every question and written whole on every change,
/// so what it says is what a relaunched app will find.
public struct Manifest: Sendable {
  private let file: URL

  /// - Parameter file: Where the list is kept; it need not exist yet.
  public init(file: URL) {
    self.file = file
  }

  /// The consignments listed; none when nothing readable is kept.
  public func consignments() -> [Consignment] {
    guard
      let data = try? Data(contentsOf: file),
      let list = try? JSONDecoder().decode([Consignment].self, from: data)
    else {
      return []
    }
    return list
  }

  /// Replaces the list with what the change makes of it.
  public func alter(_ change: ([Consignment]) throws -> [Consignment]) throws {
    let list = try change(consignments())
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try JSONEncoder().encode(list).write(to: file, options: .atomic)
  }
}
