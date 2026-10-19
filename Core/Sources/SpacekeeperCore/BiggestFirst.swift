/// Sized things ordered from the biggest to the smallest.
public struct BiggestFirst<Item: Sized> {
  private let items: [Item]

  public init(_ items: [Item]) {
    self.items = items
  }

  /// The things themselves, biggest first.
  public func ranked() -> [Item] {
    items.sorted { $0.bytes() > $1.bytes() }
  }

  /// Bytes all of them take together.
  public func total() -> Int64 {
    items.reduce(0) { $0 + $1.bytes() }
  }

  /// Bytes of them that sit on the device, which is the most that removing them could free.
  public func onDevice() -> Int64 {
    items.reduce(0) { $0 + $1.onDevice() }
  }
}

extension BiggestFirst: Sendable where Item: Sendable {}
