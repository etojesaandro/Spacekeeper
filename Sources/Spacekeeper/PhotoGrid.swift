import SpacekeeperCore
import SwiftUI
import UIKit

/// Library items as a grid of square pictures, the way Photos shows them.
///
/// Every picture carries the item's size, and a video its length; an item
/// only in iCloud, or already on its way to the cloud, says so. In
/// selection a tap marks or unmarks an item, and a finger slid sideways
/// marks or unmarks every item it passes, as in Photos.
struct PhotoGrid<Header: View>: View {
  private let items: [MediaItem]
  private let columns: Binding<Int>
  private let selecting: Bool
  private let chosen: Binding<Set<String>>
  private let away: Set<String>
  private let open: (MediaItem) -> Void
  private let header: Header
  @ViewState private var sweep: [Sweep] = []
  @ViewState private var width: CGFloat = 0

  /// - Parameters:
  ///   - items: The items, in the order to show them.
  ///   - columns: How many pictures make a row.
  ///   - selecting: Whether taps mark items rather than open them.
  ///   - chosen: Identifiers of the marked items.
  ///   - away: Identifiers of the items on their way to the cloud.
  ///   - open: Told which item the user tapped outside selection.
  ///   - header: What scrolls above the pictures.
  init(
    items: [MediaItem],
    columns: Binding<Int>,
    selecting: Bool,
    chosen: Binding<Set<String>>,
    away: Set<String>,
    open: @escaping (MediaItem) -> Void,
    @ViewBuilder header: () -> Header
  ) {
    self.items = items
    self.columns = columns
    self.selecting = selecting
    self.chosen = chosen
    self.away = away
    self.open = open
    self.header = header()
  }

  var body: some View {
    // The scroll view sits right in the navigation stack, so the large title
    // collapses as the grid scrolls; the grid's width is read from behind it.
    let side = side(in: width)
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header
        LazyVGrid(
          columns: Array(repeating: GridItem(.fixed(side), spacing: gap), count: columns.wrappedValue),
          spacing: gap
        ) {
          ForEach(items) { item in
            GridCell(
              item: item,
              side: side,
              selecting: selecting,
              marked: chosen.wrappedValue.contains(item.id),
              away: away.contains(item.id)
            )
            .onTapGesture {
              tapped(item)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Only the pictures take the pinch and the slide; the header's controls keep their taps.
        .simultaneousGesture(selecting ? slide(side: side) : nil)
        .simultaneousGesture(
          MagnifyGesture()
            .onEnded { value in
              regrid(value.magnification)
            }
        )
      }
      .background {
        GeometryReader { frame in
          Color.clear
            .onAppear {
              width = frame.size.width
            }
            .onChange(of: frame.size.width) { _, now in
              width = now
            }
        }
      }
    }
    .sensoryFeedback(.selection, trigger: chosen.wrappedValue.count)
  }

  private let gap: CGFloat = 2

  private func side(in width: CGFloat) -> CGFloat {
    // Before the first measure, the screen's width is the best guess.
    let width = width > 0 ? width : UIScreen.main.bounds.width
    let count = CGFloat(columns.wrappedValue)
    return max(1, ((width - gap * (count - 1)) / count).rounded(.down))
  }

  private func tapped(_ item: MediaItem) {
    guard selecting else {
      open(item)
      return
    }
    guard !away.contains(item.id) else {
      return
    }
    if chosen.wrappedValue.contains(item.id) {
      chosen.wrappedValue.remove(item.id)
    } else {
      chosen.wrappedValue.insert(item.id)
    }
  }

  /// Spreading two fingers shows fewer, larger pictures; pinching shows more.
  private func regrid(_ magnification: CGFloat) {
    let steps = [7, 5, 3]
    let now = steps.firstIndex(of: columns.wrappedValue) ?? 1
    if magnification > 1.25, now < steps.count - 1 {
      withAnimation(.snappy) {
        columns.wrappedValue = steps[now + 1]
      }
    } else if magnification < 0.8, now > 0 {
      withAnimation(.snappy) {
        columns.wrappedValue = steps[now - 1]
      }
    }
  }

  /// The sideways slide that marks items in a row, as in Photos.
  ///
  /// A slide that starts upright is the scroll's, and is left alone.
  private func slide(side: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 12, coordinateSpace: .local)
      .onChanged { value in
        if sweep.isEmpty {
          let across = abs(value.translation.width) > abs(value.translation.height)
          let first = index(at: value.startLocation, side: side)
          guard across, let first, !away.contains(items[first].id) else {
            sweep = [Sweep(first: -1, adding: false, before: [])]
            return
          }
          sweep = [
            Sweep(
              first: first,
              adding: !chosen.wrappedValue.contains(items[first].id),
              before: chosen.wrappedValue
            )
          ]
        }
        guard let now = sweep.first, now.first >= 0,
          let last = index(at: value.location, side: side)
        else {
          return
        }
        let passed = Set(
          items[min(now.first, last)...max(now.first, last)].map { $0.id }
        ).subtracting(away)
        chosen.wrappedValue = now.adding
          ? now.before.union(passed) : now.before.subtracting(passed)
      }
      .onEnded { _ in
        sweep = []
      }
  }

  /// The position, among the items, of the picture under a point of the grid.
  private func index(at point: CGPoint, side: CGFloat) -> Int? {
    let count = columns.wrappedValue
    let column = min(count - 1, max(0, Int(point.x / (side + gap))))
    let row = max(0, Int(point.y / (side + gap)))
    let index = row * count + column
    return items.indices.contains(index) ? index : nil
  }

  /// Where a sliding selection began and what it does.
  private struct Sweep {
    let first: Int
    let adding: Bool
    let before: Set<String>
  }
}

/// One square of the grid: the picture and what is worth knowing about the item.
struct GridCell: View {
  let item: MediaItem
  let side: CGFloat
  let selecting: Bool
  let marked: Bool
  let away: Bool

  var body: some View {
    LibraryPicture(id: item.id, side: side)
      .overlay(alignment: .bottom) {
        // A soft shade keeps the white labels readable on bright pictures.
        LinearGradient(
          colors: [.clear, .black.opacity(0.45)],
          startPoint: .top,
          endPoint: .bottom
        )
        .frame(height: min(side * 0.45, 36))
        .allowsHitTesting(false)
      }
      .overlay(alignment: .bottomLeading) {
        Text(item.bytes().formatted(.byteCount(style: .file)))
          .font(.caption2.weight(.semibold).monospacedDigit())
          .foregroundStyle(.white)
          .lineLimit(1)
          .minimumScaleFactor(0.7)
          .padding(.horizontal, 4)
          .padding(.bottom, 3)
      }
      .overlay(alignment: .bottomTrailing) {
        if item.video, side > 60 {
          Text(Duration.seconds(item.seconds.rounded()).formatted(.time(pattern: .minuteSecond)))
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.bottom, 3)
        }
      }
      .overlay(alignment: .topLeading) {
        if item.onDevice() == 0 {
          Image(systemName: "icloud")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(4)
        }
      }
      .overlay {
        if away {
          ZStack {
            Color.black.opacity(0.35)
            Image(systemName: "arrow.up.circle.fill")
              .font(.title3)
              .foregroundStyle(.white)
          }
        } else if selecting && marked {
          Color.white.opacity(0.25)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if selecting, !away {
          Image(systemName: marked ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, marked ? Color.accentColor : .black.opacity(0.2))
            .shadow(radius: 1)
            .padding(4)
        }
      }
      .contentShape(Rectangle())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(spoken)
      .accessibilityAddTraits(marked ? [.isButton, .isSelected] : .isButton)
  }

  /// What VoiceOver says about the item.
  private var spoken: String {
    var parts = [item.video ? String(localized: "Video") : String(localized: "Photo")]
    if item.video {
      parts.append(
        Duration.seconds(item.seconds.rounded()).formatted(.units(allowed: [.minutes, .seconds]))
      )
    }
    parts.append(item.bytes().formatted(.byteCount(style: .file)))
    parts.append(item.created.formatted(date: .long, time: .omitted))
    if item.onDevice() == 0 {
      parts.append(String(localized: "only in iCloud"))
    }
    if away {
      parts.append(String(localized: "on its way to the cloud"))
    }
    return parts.joined(separator: ", ")
  }
}
