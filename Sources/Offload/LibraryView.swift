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
            Button(all ? "Deselect All" : "Select All") {
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
          Button("Move \(count(chosen.count))") {
            finish(.move)
          }
        } else {
          Button("Delete \(count(chosen.count))", role: .destructive) {
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
        if listed.isEmpty, findings.items.count > 0 {
          ContentUnavailableView(
            "Nothing here",
            systemImage: "photo.on.rectangle",
            description: Text("No \(kind.wrappedValue.noun) in this period.")
          )
        }
      }
    }
  }

  /// The totals above the pictures, and the choice between items, years and months.
  private var summary: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(listed.count.formatted()) items · \(size(listed.reduce(0) { $0 + $1.bytes() }))")
          .font(.subheadline.weight(.semibold))
        let away = listed.reduce(0) { $0 + ($1.bytes() - $1.onDevice()) }
        if away > 0 {
          Label("\(size(away)) of it only in iCloud", systemImage: "icloud")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      if period == .always, !selecting {
        Picker("Show", selection: $view) {
          Text("All").tag(Lens.all)
          Text("Years").tag(Lens.years)
          Text("Months").tag(Lens.months)
        }
        .pickerStyle(.segmented)
        TipView(SelectionTip())
      }
    }
    .padding(.horizontal)
    .padding(.bottom, 10)
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
    switch period {
    case .always:
      return "Library"
    case .year(let year):
      return String(year)
    case .month(let year, let month):
      let names = Calendar.current.standaloneMonthSymbols
      return names.indices.contains(month - 1) ? "\(names[month - 1]) \(year)" : String(year)
    }
  }

  private var picked: String {
    chosen.isEmpty ? "Select Items" : "\(count(chosen.count)) Selected"
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
      ? "Move \(count(chosen.count)) to \(clouds.name)?"
      : "Delete \(count(chosen.count)) without a copy?"
  }

  private var warning: String {
    let freed = size(marked.reduce(0) { $0 + $1.onDevice() })
    return asking.first == .move
      ? "They are uploaded and checked, then deleted from this iPhone, freeing about \(freed). "
        + "iOS asks you to confirm the deletion."
      : "No copy is made. They go to Recently Deleted, freeing about \(freed) once it is emptied."
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

  private func count(_ number: Int) -> String {
    number == 1 ? "1 Item" : "\(number.formatted()) Items"
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
      return "All items"
    case .photos:
      return "Photos"
    case .videos:
      return "Videos"
    case .onPhone:
      return "On this iPhone"
    case .iCloud:
      return "Only in iCloud"
    }
  }

  /// The word for such items in a sentence.
  var noun: String {
    switch self {
    case .all:
      return "items"
    case .photos:
      return "photos"
    case .videos:
      return "videos"
    case .onPhone:
      return "items on this iPhone"
    case .iCloud:
      return "items only in iCloud"
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
    GeometryReader { frame in
      let side = ((frame.size.width - 16 * 3) / 2).rounded(.down)
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          header
          LazyVGrid(columns: [GridItem(.fixed(side), spacing: 16), GridItem(.fixed(side))], spacing: 16) {
            ForEach(spans) { span in
              NavigationLink {
                destination(span)
              } label: {
                card(span, side: side)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, 16)
          .padding(.bottom, 16)
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
        Text(name(of: span.period))
          .font(.headline)
        Text("\(span.bytes.formatted(.byteCount(style: .file))) · \(span.count.formatted()) items")
          .font(.footnote.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func name(of period: Period) -> String {
    switch period {
    case .always:
      return "All time"
    case .year(let year):
      return String(year)
    case .month(let year, let month):
      let names = Calendar.current.monthSymbols
      return names.indices.contains(month - 1) ? "\(names[month - 1]) \(year)" : String(year)
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
      Text(count == 0 ? "Tap or slide across items" : "\(bytes.formatted(.byteCount(style: .file))) selected")
        .font(.footnote.weight(.semibold).monospacedDigit())
        .foregroundStyle(.secondary)
      ActionBar {
        ActionButton("Delete", symbol: "trash", tint: .red, spoken: "Delete without a copy") {
          act(.delete)
        }
        ActionButton("Copy", symbol: "doc.on.doc", tint: .primary, spoken: "Copy to \(cloud)") {
          act(.copy)
        }
        ActionButton("Move", symbol: "icloud.and.arrow.up.fill", spoken: "Move to \(cloud)") {
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
    .accessibilityLabel("Actions for \(count) selected items, to \(cloud)")
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
    .accessibilityLabel(clouds.connected ? "Clouds and accounts" : "Connect a cloud")
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
