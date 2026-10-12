import OffloadCore
import SwiftUI

/// The finished survey: totals on top, then the items of a period in an order.
///
/// Outside selection a tap picks one item; in selection a tap marks or
/// unmarks it. Items already on their way to the cloud are shown as such
/// and cannot be picked again.
struct RankingView: View {
  private let findings: Survey.Findings
  private let selecting: Bool
  private let chosen: Binding<Set<String>>
  private let away: Set<String>
  private let arrange: (Period, Order) -> Void
  private let pick: (MediaItem) -> Void
  @ViewState private var shown = 100

  /// - Parameters:
  ///   - findings: What the survey found.
  ///   - selecting: Whether taps mark items rather than pick one.
  ///   - chosen: Identifiers of the marked items.
  ///   - away: Identifiers of the items already on their way to the cloud.
  ///   - arrange: Told which period and order the user wants listed.
  ///   - pick: Told which item the user tapped outside selection.
  init(
    findings: Survey.Findings,
    selecting: Bool,
    chosen: Binding<Set<String>>,
    away: Set<String>,
    arrange: @escaping (Period, Order) -> Void,
    pick: @escaping (MediaItem) -> Void
  ) {
    self.findings = findings
    self.selecting = selecting
    self.chosen = chosen
    self.away = away
    self.arrange = arrange
    self.pick = pick
  }

  var body: some View {
    List {
      Section {
        LabeledContent("Photos and videos", value: findings.items.count.formatted())
        LabeledContent("Full size", value: size(findings.total))
        LabeledContent("On this iPhone", value: size(findings.onDevice))
        LabeledContent("Only in iCloud", value: size(findings.total - findings.onDevice))
      } footer: {
        Text("Read in \(findings.seconds.formatted(.number.precision(.fractionLength(1)))) s.")
      }
      Section {
        HStack {
          Menu {
            ForEach(Order.allCases, id: \.self) { order in
              Button {
                rearrange(findings.period, order)
              } label: {
                if order == findings.order {
                  Label(title(of: order), systemImage: "checkmark")
                } else {
                  Text(title(of: order))
                }
              }
            }
          } label: {
            Label(title(of: findings.order), systemImage: "arrow.up.arrow.down")
          }
          Spacer()
          Menu {
            Button("All time") {
              rearrange(.always, findings.order)
            }
            ForEach(years, id: \.year.period) { year, months in
              Menu("\(title(of: year.period)) · \(size(year.bytes))") {
                Button("All of \(title(of: year.period)) · \(weight(of: year))") {
                  rearrange(year.period, findings.order)
                }
                ForEach(months) { month in
                  Button("\(title(of: month.period)) · \(weight(of: month))") {
                    rearrange(month.period, findings.order)
                  }
                }
              }
            }
          } label: {
            Label(title(of: findings.period), systemImage: "calendar")
          }
        }
        .buttonStyle(.borderless)
        if selecting, !findings.listed.isEmpty {
          Button(marked ? "Unmark these" : "Mark all \(markable.count) listed here") {
            if marked {
              chosen.wrappedValue.subtract(markable)
            } else {
              chosen.wrappedValue.formUnion(markable)
            }
          }
        }
        ForEach(findings.listed.prefix(shown)) { item in
          Button {
            tapped(item)
          } label: {
            HStack(spacing: 12) {
              if away.contains(item.id) {
                Image(systemName: "arrow.up.circle.fill")
                  .font(.title3)
                  .foregroundStyle(Color.secondary)
              } else if selecting {
                Image(
                  systemName: chosen.wrappedValue.contains(item.id)
                    ? "checkmark.circle.fill" : "circle"
                )
                .font(.title3)
                .foregroundStyle(
                  chosen.wrappedValue.contains(item.id) ? Color.accentColor : Color.secondary
                )
              }
              ItemRow(item: item)
            }
          }
          .buttonStyle(.plain)
          .disabled(selecting && away.contains(item.id))
        }
        if findings.listed.count > shown {
          Button("Show \(min(200, findings.listed.count - shown)) more") {
            shown += 200
          }
        }
        if findings.listed.isEmpty {
          Text("Nothing from this period.")
            .foregroundStyle(.secondary)
        }
      } header: {
        Text(
          "\(findings.listed.count.formatted()) items · "
            + size(findings.listed.reduce(0) { $0 + $1.bytes() })
        )
      } footer: {
        Text(
          selecting
            ? "Tap the items to move, then use the button below."
            : "Tap an item to look at it and move it to Yandex Disk, or use Select for several."
        )
      }
    }
  }

  /// The spans of the findings as years, each with its months.
  private var years: [(year: Span, months: [Span])] {
    var years: [(year: Span, months: [Span])] = []
    for span in findings.spans {
      if case .month = span.period, !years.isEmpty {
        years[years.count - 1].months.append(span)
      } else {
        years.append((span, []))
      }
    }
    return years
  }

  /// Identifiers of the listed items that can be marked.
  private var markable: Set<String> {
    Set(findings.listed.prefix(shown).map { $0.id }).subtracting(away)
  }

  /// Whether every listed item that can be marked is marked.
  private var marked: Bool {
    !markable.isEmpty && markable.isSubset(of: chosen.wrappedValue)
  }

  private func rearrange(_ period: Period, _ order: Order) {
    shown = 100
    arrange(period, order)
  }

  private func tapped(_ item: MediaItem) {
    guard selecting else {
      pick(item)
      return
    }
    if chosen.wrappedValue.contains(item.id) {
      chosen.wrappedValue.remove(item.id)
    } else {
      chosen.wrappedValue.insert(item.id)
    }
  }

  private func title(of order: Order) -> String {
    switch order {
    case .biggest:
      return "Biggest first"
    case .smallest:
      return "Smallest first"
    case .newest:
      return "Newest first"
    case .oldest:
      return "Oldest first"
    }
  }

  private func title(of period: Period) -> String {
    switch period {
    case .always:
      return "All time"
    case .year(let year):
      return String(year)
    case .month(let year, let month):
      let names = Calendar.current.standaloneMonthSymbols
      return names.indices.contains(month - 1) ? "\(names[month - 1]) \(year)" : String(year)
    }
  }

  private func weight(of span: Span) -> String {
    "\(size(span.bytes)) · \(span.count.formatted())"
  }

  private func size(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file))
  }
}

/// One line of the list.
private struct ItemRow: View {
  let item: MediaItem

  var body: some View {
    HStack(spacing: 12) {
      Thumbnail(id: item.id, side: 56)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.name)
          .font(.subheadline)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        Text(item.bytes().formatted(.byteCount(style: .file)))
          .font(.subheadline.monospacedDigit())
        if item.onDevice() < item.bytes() {
          Label(item.onDevice() == 0 ? "iCloud only" : "Partly in iCloud", systemImage: "icloud")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
    }
    .contentShape(Rectangle())
  }

  private var detail: String {
    let date = item.created.formatted(date: .abbreviated, time: .omitted)
    guard item.video else {
      return "Photo · \(date)"
    }
    let length = Duration.seconds(item.seconds.rounded())
      .formatted(.time(pattern: .minuteSecond))
    return "Video · \(length) · \(date)"
  }
}
