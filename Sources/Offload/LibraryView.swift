import OffloadCore
import SwiftUI
import TipKit
import UIKit

/// The Library tab: the photo library as it is read, then as a grid, biggest first.
struct LibraryTab: View {
  private let survey: Survey
  private let uploads: Uploads
  private let clouds: Clouds
  private let account: () -> Void
  private let act: (Deed, [MediaItem]) -> Void
  @ViewState private var order = Order.biggest
  @ViewState private var kind = Kind.all
  @ViewState private var columns = 3

  /// - Parameters:
  ///   - survey: The library survey to show.
  ///   - uploads: The move of items to the cloud.
  ///   - clouds: Which cloud items go to.
  ///   - account: Opens the clouds and accounts.
  ///   - act: Told what the user decided to do with which items.
  init(
    survey: Survey,
    uploads: Uploads,
    clouds: Clouds,
    account: @escaping () -> Void,
    act: @escaping (Deed, [MediaItem]) -> Void
  ) {
    self.survey = survey
    self.uploads = uploads
    self.clouds = clouds
    self.account = account
    self.act = act
  }

  var body: some View {
    NavigationStack {
      Group {
        switch survey.stage {
        case .waiting:
          ProgressView()
        case .refused:
          ContentUnavailableView {
            Label("No access to Photos", systemImage: "lock.fill")
          } description: {
            Text("Offload needs to see your photos to show which ones take the most space.")
          } actions: {
            Button("Open Settings") {
              if let settings = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(settings)
              }
            }
            .buttonStyle(.borderedProminent)
          }
        case .reading(let done, let of):
          ContentUnavailableView {
            Label("Reading your library", systemImage: "photo.stack")
          } description: {
            VStack(spacing: 12) {
              Text("Offload weighs every photo and video once; later it only looks at what is new.")
              ProgressView(value: Double(done), total: Double(max(of, 1)))
                .frame(maxWidth: 240)
              Text("\(done.formatted()) of \(of.formatted())")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
        case .ranked(let findings):
          LibraryBrowser(
            findings: findings,
            period: .always,
            uploads: uploads,
            clouds: clouds,
            order: $order,
            kind: $kind,
            columns: $columns,
            act: act
          )
          .refreshable {
            await survey.afresh()
          }
        }
      }
      .navigationTitle("Library")
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          AccountButton(clouds: clouds, open: account)
        }
      }
    }
  }
}

/// The items of one period: as a grid, or for all of time also as years or months.
struct LibraryBrowser: View {
  private let findings: Survey.Findings
  private let period: Period
  private let uploads: Uploads
  private let clouds: Clouds
  private let order: Binding<Order>
  private let kind: Binding<Kind>
  private let columns: Binding<Int>
  private let act: (Deed, [MediaItem]) -> Void
  @ViewState private var view = Lens.all
  @ViewState private var listed: [MediaItem] = []
  @ViewState private var arranged = false
  @ViewState private var covers: [Period: MediaItem] = [:]
  @ViewState private var selecting = false
  @ViewState private var chosen: Set<String> = []
  @ViewState private var viewing: [Viewing] = []
  @ViewState private var asking: [Deed] = []

  /// - Parameters:
  ///   - findings: What the survey found.
  ///   - period: The stretch of time whose items are shown.
  ///   - uploads: The move of items to the cloud.
  ///   - clouds: Which cloud items go to.
  ///   - order: The order items are listed in.
  ///   - kind: Which kind of items are listed.
  ///   - columns: How many pictures make a row.
  ///   - act: Told what the user decided to do with which items.
  init(
    findings: Survey.Findings,
    period: Period,
    uploads: Uploads,
    clouds: Clouds,
    order: Binding<Order>,
    kind: Binding<Kind>,
    columns: Binding<Int>,
    act: @escaping (Deed, [MediaItem]) -> Void
  ) {
    self.findings = findings
    self.period = period
    self.uploads = uploads
    self.clouds = clouds
    self.order = order
    self.kind = kind
    self.columns = columns
    self.act = act
  }

  var body: some View {
    content
      .navigationTitle(selecting ? picked : title)
      .navigationBarTitleDisplayMode(period == .always && !selecting ? .large : .inline)
      .toolbar {
        if selecting {
          ToolbarItem(placement: .topBarLeading) {
            Button(all ? String(localized: "Deselect All") : String(localized: "Select All")) {
              chosen = all ? [] : markable
            }
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button("Cancel") {
              leave()
            }
            .fontWeight(.semibold)
          }
        } else {
          ToolbarItemGroup(placement: .topBarTrailing) {
            arrangement
            if view == .all || period != .always {
              Button("Select") {
                selecting = true
              }
            }
          }
        }
      }
      .toolbar(selecting ? .hidden : .automatic, for: .tabBar)
      .safeAreaInset(edge: .bottom) {
        if period == .always, !selecting {
          lenses
        }
      }
      .safeAreaInset(edge: .bottom) {
        if selecting {
          SelectionBar(
            count: chosen.count,
            bytes: marked.reduce(0) { $0 + $1.bytes() },
            cloud: clouds.name
          ) { deed in
            if deed == .copy {
              finish(deed)
            } else {
              asking = [deed]
            }
          }
        }
      }
      .confirmationDialog(
        question,
        isPresented: Binding(get: { !asking.isEmpty }, set: { _ in asking = [] }),
        titleVisibility: .visible
      ) {
        if asking.first == .move {
          Button(String(localized: "Move \(chosen.count) items")) {
            finish(.move)
          }
        } else {
          Button(String(localized: "Delete \(chosen.count) items"), role: .destructive) {
            finish(.delete)
          }
        }
      } message: {
        Text(warning)
      }
      .fullScreenCover(
        isPresented: Binding(get: { !viewing.isEmpty }, set: { _ in viewing = [] })
      ) {
        if let viewing = viewing.first {
          LibraryViewer(
            items: viewing.items,
            start: viewing.start,
            uploads: uploads,
            cloud: clouds.name
          ) { deed, item in
            act(deed, [item])
          }
        }
      }
      .task(id: Arrangement(
        order: order.wrappedValue,
        kind: kind.wrappedValue,
        count: findings.items.count,
        bytes: findings.total
      )) {
        arrange()
      }
  }

  @ViewBuilder private var content: some View {
    if period == .always, view != .all, !selecting {
      SpanCards(
        spans: findings.spans.filter { span in
          if case .year = span.period {
            return view == .years
          }
          return view == .months
        },
        covers: covers
      ) {
        summary
      } destination: { span in
        LibraryBrowser(
          findings: findings,
          period: span.period,
          uploads: uploads,
          clouds: clouds,
          order: order,
          kind: kind,
          columns: columns,
          act: act
        )
      }
    } else {
      PhotoGrid(
        items: listed,
        columns: columns,
        selecting: selecting,
        chosen: $chosen,
        away: away,
        open: { item in
          viewing = [Viewing(items: listed, start: item.id)]
        }
      ) {
        summary
      }
      .overlay {
        // Shown only once the items are worked out, and never over the controls.
        if arranged, listed.isEmpty {
          ContentUnavailableView(
            "Nothing here",
            systemImage: "photo.on.rectangle",
            description: Text(kind.wrappedValue.missing)
          )
          .allowsHitTesting(false)
        }
      }
    }
  }

  /// The totals above the pictures, and the choice between items, years and months.
  private var summary: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: "\(String(localized: "\(listed.count) items")) · \(size(listed.reduce(0) { $0 + $1.bytes() }))")
          .font(.subheadline.weight(.semibold))
        let away = listed.reduce(0) { $0 + ($1.bytes() - $1.onDevice()) }
        if away > 0 {
          Label(String(localized: "\(size(away)) of it only in iCloud"), systemImage: "icloud")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      if period == .always, !selecting {
        TipView(SelectionTip())
      }
    }
    .padding(.horizontal)
    .padding(.bottom, 10)
  }

  /// The choice between items, years and months, floating above the bottom as in Photos.
  private var lenses: some View {
    Picker("Show", selection: $view) {
      Text("Years").tag(Lens.years)
      Text("Months").tag(Lens.months)
      Text("All").tag(Lens.all)
    }
    .pickerStyle(.segmented)
    .frame(maxWidth: 300)
    .padding(6)
    .background(.regularMaterial, in: Capsule())
    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    .padding(.bottom, 8)
    .frame(maxWidth: .infinity)
  }

  /// The menu that orders and filters what is listed.
  private var arrangement: some View {
    Menu {
      Picker("Order", selection: order) {
        Label("Biggest first", systemImage: "arrow.down.circle").tag(Order.biggest)
        Label("Smallest first", systemImage: "arrow.up.circle").tag(Order.smallest)
        Label("Newest first", systemImage: "calendar").tag(Order.newest)
        Label("Oldest first", systemImage: "clock.arrow.circlepath").tag(Order.oldest)
      }
      Picker("Show", selection: kind) {
        ForEach(Kind.allCases, id: \.self) { kind in
          Label(kind.title, systemImage: kind.symbol).tag(kind)
        }
      }
    } label: {
      Label(
        "Sort and filter",
        systemImage: kind.wrappedValue == .all
          ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill"
      )
    }
  }

  private var title: String {
    period == .always ? String(localized: "Library") : PeriodName(period).value()
  }

  private var picked: String {
    chosen.isEmpty ? String(localized: "Select Items") : String(localized: "\(chosen.count) selected")
  }

  private var away: Set<String> {
    Set(uploads.queue.map { $0.id })
  }

  private var markable: Set<String> {
    Set(listed.map { $0.id }).subtracting(away)
  }

  private var all: Bool {
    !markable.isEmpty && markable.isSubset(of: chosen)
  }

  /// The marked items, in the order listed.
  private var marked: [MediaItem] {
    listed.filter { chosen.contains($0.id) }
  }

  private var question: String {
    asking.first == .move
      ? String(localized: "Move \(chosen.count) items to \(clouds.name)?")
      : String(localized: "Delete \(chosen.count) items without a copy?")
  }

  private var warning: String {
    let freed = size(marked.reduce(0) { $0 + $1.onDevice() })
    return asking.first == .move
      ? String(
        localized: "They are uploaded and checked, then deleted from this iPhone, freeing about \(freed). iOS asks you to confirm the deletion."
      )
      : String(
        localized: "No copy is made. They go to Recently Deleted, freeing about \(freed) once it is emptied."
      )
  }

  private func finish(_ deed: Deed) {
    let items = marked
    leave()
    act(deed, items)
  }

  private func leave() {
    selecting = false
    chosen = []
  }

  private func arrange() {
    let almanac = Almanac(findings.items, calendar: .current)
    listed = almanac.items(of: period, by: order.wrappedValue).filter(kind.wrappedValue.holds)
    arranged = true
    guard period == .always else {
      return
    }
    // The items come biggest first, so the first of each year and month is its biggest.
    var found: [Period: MediaItem] = [:]
    let calendar = Calendar.current
    for item in findings.items {
      let parts = calendar.dateComponents([.year, .month], from: item.created)
      let year = Period.year(parts.year ?? 0)
      let month = Period.month(parts.year ?? 0, parts.month ?? 0)
      if found[year] == nil {
        found[year] = item
      }
      if found[month] == nil {
        found[month] = item
      }
    }
    covers = found
  }

  private func size(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file))
  }

  /// How all of time is looked at.
  private enum Lens: Hashable {
    case all
    case years
    case months
  }

  /// What the listed items depend on, so they are worked out again when it changes.
  private struct Arrangement: Equatable {
    let order: Order
    let kind: Kind
    let count: Int
    let bytes: Int64
  }
}

/// Library items to look through one by one, and the one to start at.
struct Viewing {
  let items: [MediaItem]
  let start: String
}

/// Which items are listed.
enum Kind: CaseIterable, Hashable {
  case all
  case photos
  case videos
  case onPhone
  case iCloud

  var title: String {
    switch self {
    case .all:
      return String(localized: "All items")
    case .photos:
      return String(localized: "Photos")
    case .videos:
      return String(localized: "Videos")
    case .onPhone:
      return String(localized: "On this iPhone")
    case .iCloud:
      return String(localized: "Only in iCloud")
    }
  }

  /// What a period without such items says.
  var missing: String {
    switch self {
    case .all:
      return String(localized: "Nothing from this period.")
    case .photos:
      return String(localized: "No photos in this period.")
    case .videos:
      return String(localized: "No videos in this period.")
    case .onPhone:
      return String(localized: "Nothing from this period is on this iPhone.")
    case .iCloud:
      return String(localized: "Nothing from this period is only in iCloud.")
    }
  }

  var symbol: String {
    switch self {
    case .all:
      return "square.grid.2x2"
    case .photos:
      return "photo"
    case .videos:
      return "video"
    case .onPhone:
      return "iphone"
    case .iCloud:
      return "icloud"
    }
  }

  func holds(_ item: MediaItem) -> Bool {
    switch self {
    case .all:
      return true
    case .photos:
      return !item.video
    case .videos:
      return item.video
    case .onPhone:
      return item.onDevice() > 0
    case .iCloud:
      return item.onDevice() == 0
    }
  }
}

/// Years or months as cards, each with its biggest picture and its weight.
struct SpanCards<Header: View, Destination: View>: View {
  private let spans: [Span]
  private let covers: [Period: MediaItem]
  private let header: Header
  private let destination: (Span) -> Destination
  @ViewState private var width: CGFloat = 0

  init(
    spans: [Span],
    covers: [Period: MediaItem],
    @ViewBuilder header: () -> Header,
    @ViewBuilder destination: @escaping (Span) -> Destination
  ) {
    self.spans = spans
    self.covers = covers
    self.header = header()
    self.destination = destination
  }

  var body: some View {
    let side = ((width > 0 ? width : UIScreen.main.bounds.width) - 16 * 3) / 2
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header
        LazyVGrid(columns: [GridItem(.fixed(side.rounded(.down)), spacing: 16), GridItem(.fixed(side.rounded(.down)))], spacing: 16) {
          ForEach(spans) { span in
            NavigationLink {
              destination(span)
            } label: {
              card(span, side: side.rounded(.down))
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
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
  }

  private func card(_ span: Span, side: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Group {
        if let cover = covers[span.period] {
          LibraryPicture(id: cover.id, side: side)
        } else {
          Color(.secondarySystemFill)
            .frame(width: side, height: side)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      VStack(alignment: .leading, spacing: 1) {
        Text(PeriodName(span.period).value())
          .font(.headline)
        Text(verbatim: "\(span.bytes.formatted(.byteCount(style: .file))) · \(String(localized: "\(span.count) items"))")
          .font(.footnote.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

}

/// The name of a year or a month as people of the user's language write it.
struct PeriodName {
  private let period: Period

  init(_ period: Period) {
    self.period = period
  }

  func value() -> String {
    switch period {
    case .always:
      return String(localized: "All time")
    case .year(let year):
      return String(year)
    case .month(let year, let month):
      let calendar = Calendar.current
      guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)) else {
        return String(year)
      }
      // The template lets each language put the month and year its own way.
      let format = DateFormatter()
      format.locale = .current
      format.setLocalizedDateFormatFromTemplate("LLLLy")
      return format.string(from: first).capitalized(with: .current)
    }
  }
}

/// The bar at the bottom while items are selected: how much they weigh, and what to do.
struct SelectionBar: View {
  let count: Int
  let bytes: Int64
  let cloud: String
  let act: (Deed) -> Void

  var body: some View {
    VStack(spacing: 6) {
      Text(
        count == 0
          ? String(localized: "Tap or slide across items")
          : String(localized: "\(bytes.formatted(.byteCount(style: .file))) selected")
      )
        .font(.footnote.weight(.semibold).monospacedDigit())
        .foregroundStyle(.secondary)
      ActionBar {
        ActionButton("Delete", symbol: "trash", tint: .red, spoken: String(localized: "Delete without a copy")) {
          act(.delete)
        }
        ActionButton("Copy", symbol: "doc.on.doc", tint: .primary, spoken: String(localized: "Copy to \(cloud)")) {
          act(.copy)
        }
        ActionButton("Move", symbol: "icloud.and.arrow.up.fill", spoken: String(localized: "Move to \(cloud)")) {
          act(.move)
        }
      }
      .disabled(count == 0)
    }
    .padding(.horizontal, 8)
    .padding(.top, 8)
    .padding(.bottom, 4)
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(String(localized: "Actions for the selection, to \(cloud)"))
  }
}

/// The button that opens the clouds and accounts, showing whether one is connected.
struct AccountButton: View {
  let clouds: Clouds
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      Image(systemName: clouds.connected ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.exclamationmark")
        .symbolRenderingMode(.hierarchical)
    }
    .accessibilityLabel(
      clouds.connected ? String(localized: "Clouds and accounts") : String(localized: "Connect a cloud")
    )
  }
}

/// A one-time hint about selecting many items at once.
struct SelectionTip: Tip {
  var title: Text {
    Text("Free space in one go")
  }

  var message: Text? {
    Text("Tap Select, then slide your finger across pictures to pick many at once.")
  }

  var image: Image? {
    Image(systemName: "hand.draw")
  }
}
