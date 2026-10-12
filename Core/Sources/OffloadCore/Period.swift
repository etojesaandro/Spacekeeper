import Foundation

/// A stretch of time library items are picked by.
public enum Period: Hashable, Sendable {
  /// All of time.
  case always

  /// One calendar year.
  case year(Int)

  /// One month of a year, counted from one.
  case month(Int, Int)

  /// Whether the moment falls into the period, as the calendar counts.
  public func holds(_ moment: Date, in calendar: Calendar) -> Bool {
    switch self {
    case .always:
      return true
    case .year(let year):
      return calendar.component(.year, from: moment) == year
    case .month(let year, let month):
      let parts = calendar.dateComponents([.year, .month], from: moment)
      return parts.year == year && parts.month == month
    }
  }
}

/// The order library items are listed in.
public enum Order: Hashable, Sendable, CaseIterable {
  case biggest
  case smallest
  case newest
  case oldest

  /// The items in this order; equal ones keep their places.
  public func sorted(_ items: [MediaItem]) -> [MediaItem] {
    switch self {
    case .biggest:
      return items.sorted { $0.bytes() > $1.bytes() }
    case .smallest:
      return items.sorted { $0.bytes() < $1.bytes() }
    case .newest:
      return items.sorted { $0.created > $1.created }
    case .oldest:
      return items.sorted { $0.created < $1.created }
    }
  }
}

/// The years and months library items come from, with how much each holds.
public struct Almanac: Sendable {
  private let items: [MediaItem]
  private let calendar: Calendar

  /// - Parameters:
  ///   - items: The library items.
  ///   - calendar: The calendar that says which year and month a moment belongs to.
  public init(_ items: [MediaItem], calendar: Calendar) {
    self.items = items
    self.calendar = calendar
  }

  /// Every year that has items, latest first, each followed by its months, latest first.
  public func spans() -> [Span] {
    var months: [Period: (count: Int, bytes: Int64)] = [:]
    for item in items {
      let parts = calendar.dateComponents([.year, .month], from: item.created)
      let month = Period.month(parts.year ?? 0, parts.month ?? 0)
      let before = months[month] ?? (0, 0)
      months[month] = (before.count + 1, before.bytes + item.bytes())
    }
    var years: [Int: [Span]] = [:]
    for (period, sum) in months {
      if case .month(let year, _) = period {
        years[year, default: []].append(Span(period: period, count: sum.count, bytes: sum.bytes))
      }
    }
    return years.keys.sorted(by: >).flatMap { year -> [Span] in
      let within = (years[year] ?? []).sorted { $0.rank() > $1.rank() }
      return [
        Span(
          period: .year(year),
          count: within.reduce(0) { $0 + $1.count },
          bytes: within.reduce(0) { $0 + $1.bytes }
        )
      ] + within
    }
  }

  /// The items of a period, in an order.
  public func items(of period: Period, by order: Order) -> [MediaItem] {
    order.sorted(items.filter { period.holds($0.created, in: calendar) })
  }
}

/// A year or a month together with how many items it has and how much they weigh.
public struct Span: Sendable, Equatable, Identifiable {
  public let period: Period
  public let count: Int
  public let bytes: Int64

  /// - Parameters:
  ///   - period: The year or month.
  ///   - count: How many items it has.
  ///   - bytes: How much they weigh together.
  public init(period: Period, count: Int, bytes: Int64) {
    self.period = period
    self.count = count
    self.bytes = bytes
  }

  /// Menus require a readable `id`.
  public var id: Period {
    period
  }

  /// Where the span comes within its year: later months first.
  func rank() -> Int {
    if case .month(_, let month) = period {
      return month
    }
    return 0
  }
}
