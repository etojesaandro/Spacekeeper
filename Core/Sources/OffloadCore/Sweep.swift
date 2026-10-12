import Foundation

/// Moving several originals to a cloud.
///
/// Each original is copied and verified on its own, so one failure does not
/// stop the rest. Those whose copies proved identical are then removed from
/// the device together, in a single request; the others stay where they are.
public struct Sweep<Trash: Bin>: Sendable {
  private let originals: [Trash.Item]
  private let cloud: any Cloud
  private let bin: Trash
  private let onlooker: any Onlooker

  /// - Parameters:
  ///   - originals: What to move, in the order to move it.
  ///   - cloud: Where the copies go.
  ///   - bin: What removes the originals once their copies are safe.
  ///   - onlooker: Told how the sweep is getting on.
  public init(
    of originals: [Trash.Item],
    to cloud: any Cloud,
    into bin: Trash,
    watched onlooker: any Onlooker
  ) {
    self.originals = originals
    self.cloud = cloud
    self.bin = bin
    self.onlooker = onlooker
  }

  /// Copies every original, then removes those that were copied safely.
  ///
  /// - Returns: What became of each original, in the order they were given.
  public func run() async -> [Fate] {
    var fates: [Fate] = []
    var safe: [Int] = []
    for (index, original) in originals.enumerated() {
      onlooker.copying(index + 1, of: originals.count)
      do {
        try await SafeCopy(of: original, in: cloud).make()
        safe.append(index)
        fates.append(.moved)
      } catch {
        fates.append(.kept(error.localizedDescription))
      }
      await original.release()
    }
    guard !safe.isEmpty else {
      return fates
    }
    onlooker.discarding(safe.count)
    do {
      try await bin.discard(safe.map { originals[$0] })
    } catch {
      for index in safe {
        fates[index] = .copied(error.localizedDescription)
      }
    }
    return fates
  }
}

/// What removes originals from the device, several in one go.
public protocol Bin<Item>: Sendable {
  associatedtype Item: Original

  /// Removes the originals together.
  func discard(_ items: [Item]) async throws
}

/// Someone who wants to know how a sweep is getting on.
public protocol Onlooker: Sendable {
  /// The sweep starts copying the original with this number, counted from one.
  func copying(_ number: Int, of count: Int)

  /// The sweep is about to remove this many safely copied originals.
  func discarding(_ count: Int)
}

/// What became of one original in a sweep.
public enum Fate: Sendable, Hashable {
  /// Its copy is in the cloud and it is gone from the device.
  case moved

  /// Its copy is in the cloud, but it is still on the device, for the reason given.
  case copied(String)

  /// It could not be copied and is untouched, for the reason given.
  case kept(String)
}
