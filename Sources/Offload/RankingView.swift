import SwiftUI

/// The finished ranking: totals on top, then the biggest items.
struct RankingView: View {
  private let findings: Survey.Findings
  private let shown: Int
  private let pick: (LibraryItem) -> Void
  @ViewState private var smallest = false

  /// - Parameters:
  ///   - findings: What the survey found.
  ///   - shown: How many of the biggest items to list.
  ///   - pick: Told which item the user tapped.
  init(findings: Survey.Findings, shown: Int, pick: @escaping (LibraryItem) -> Void) {
    self.findings = findings
    self.shown = shown
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
            pick(item)
          } label: {
            ItemRow(item: item)
          }
          .buttonStyle(.plain)
        }
      } header: {
        Text("\(smallest ? "Smallest" : "Biggest") \(min(shown, findings.items.count))")
      } footer: {
        Text("Tap an item to move it to Yandex Disk.")
      }
    }
  }

  /// The items of the chosen end of the ranking.
  private var listed: [LibraryItem] {
    smallest
      ? Array(findings.items.suffix(shown).reversed())
      : Array(findings.items.prefix(shown))
  }

  private func size(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file))
  }
}

/// One line of the ranking.
private struct ItemRow: View {
  let item: LibraryItem

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
