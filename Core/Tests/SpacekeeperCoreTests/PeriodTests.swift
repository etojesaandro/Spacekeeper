import Foundation
import SpacekeeperCore
import Testing

@Suite("Periods and orders of library items")
struct PeriodTests {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }

  private func moment(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
  }

  private func item(_ id: String, _ size: Int64, _ created: Date) -> MediaItem {
    MediaItem(
      id: id,
      name: "\(id).JPG",
      video: false,
      seconds: 0,
      created: created,
      modified: created,
      size: size,
      local: size
    )
  }

  private var items: [MediaItem] {
    [
      item("a", 10, moment(2024, 12, 31)),
      item("b", 300, moment(2025, 3, 1)),
      item("c", 42, moment(2025, 3, 20)),
      item("d", 7, moment(2025, 1, 5)),
    ]
  }

  @Test("holds every moment when it is all of time")
  func always() {
    #expect(Period.always.holds(.distantPast, in: calendar))
    #expect(Period.always.holds(moment(2025, 3, 1), in: calendar))
  }

  @Test("holds the moments of its year only")
  func year() {
    #expect(Period.year(2025).holds(moment(2025, 1, 1), in: calendar))
    #expect(!Period.year(2025).holds(moment(2024, 12, 31), in: calendar))
  }

  @Test("holds the moments of its month only")
  func month() {
    #expect(Period.month(2025, 3).holds(moment(2025, 3, 20), in: calendar))
    #expect(!Period.month(2025, 3).holds(moment(2025, 4, 1), in: calendar))
    #expect(!Period.month(2025, 3).holds(moment(2024, 3, 20), in: calendar))
  }

  @Test("orders items by size or by date, either way round")
  func orders() {
    #expect(Order.biggest.sorted(items).map { $0.id } == ["b", "c", "a", "d"])
    #expect(Order.smallest.sorted(items).map { $0.id } == ["d", "a", "c", "b"])
    #expect(Order.newest.sorted(items).map { $0.id } == ["c", "b", "d", "a"])
    #expect(Order.oldest.sorted(items).map { $0.id } == ["a", "d", "b", "c"])
  }

  @Test("lists each year with items, latest first, followed by its months, latest first")
  func spans() {
    let spans = Almanac(items, calendar: calendar).spans()

    #expect(
      spans == [
        Span(period: .year(2025), count: 3, bytes: 349),
        Span(period: .month(2025, 3), count: 2, bytes: 342),
        Span(period: .month(2025, 1), count: 1, bytes: 7),
        Span(period: .year(2024), count: 1, bytes: 10),
        Span(period: .month(2024, 12), count: 1, bytes: 10),
      ]
    )
    #expect(spans.map { $0.id } == spans.map { $0.period })
  }

  @Test("has no spans for no items")
  func noSpans() {
    #expect(Almanac([], calendar: calendar).spans().isEmpty)
  }

  @Test("picks the items of a period in the order asked for")
  func picks() {
    let almanac = Almanac(items, calendar: calendar)

    #expect(almanac.items(of: .month(2025, 3), by: .oldest).map { $0.id } == ["b", "c"])
    #expect(almanac.items(of: .year(2025), by: .biggest).map { $0.id } == ["b", "c", "d"])
    #expect(almanac.items(of: .always, by: .smallest).map { $0.id } == ["d", "a", "c", "b"])
    #expect(almanac.items(of: .year(1999), by: .newest).isEmpty)
  }
}
