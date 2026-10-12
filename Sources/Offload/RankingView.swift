import OffloadCore
import SwiftUI

/// The finished ranking: totals on top, then the biggest items.
///
/// Outside selection a tap picks one item; in selection a tap marks or
/// unmarks it. Items already on their way to the cloud are shown as such
/// and cannot be picked again.
struct RankingView: View {
  private let findings: Survey.Findings
  private let shown: Int
  private let selecting: Bool
  private let chosen: Binding<Set<String>>
  private let away: Set<String>
  private let pick: (MediaItem) -> Void
  @ViewState private var smallest = false

  /// - Parameters:
  ///   - findings: What the survey found.
  ///   - shown: How many items of the chosen end to list.
  ///   - selecting: Whether taps mark items rather than pick one.
  ///   - chosen: Identifiers of the marked items.
  ///   - away: Identifiers of the items already on their way to the cloud.
  ///   - pick: Told which item the user tapped outside selection.
  init(
    findings: Survey.Findings,
    shown: Int,
    selecting: Bool,
    chosen: Binding<Set<String>>,
    away: Set<String>,
    pick: @escaping (MediaItem) -> Void
  ) {
    self.findings = findings
    self.shown = shown
    self.selecting = selecting
    self.chosen = chosen
    self.away = away
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
        Picker("Order", selection: $smallest) {
          Text("Biggest").tag(false)
          Text("Smallest").tag(true)
        }
        .pickerStyle(.segmented)
        ForEach(listed) { item in
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
          .disabled(away.contains(item.id))
        }
      } header: {
        Text("\(smallest ? "Smallest" : "Biggest") \(min(shown, findings.items.count))")
      } footer: {
        Text(
          selecting
            ? "Tap the items to move, then use the button below."
            : "Tap an item to move it to Yandex Disk, or use Select for several."
        )
      }
    }
  }

  /// The items of the chosen end of the ranking.
  private var listed: [MediaItem] {
    smallest
      ? Array(findings.items.suffix(shown).reversed())
      : Array(findings.items.prefix(shown))
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

  private func size(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file))
  }
}

/// One line of the ranking.
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
