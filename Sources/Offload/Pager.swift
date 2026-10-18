import AVKit
// The cross-import that gives SwiftUI its video player is not made by this build on its own.
import _AVKit_SwiftUI
import PhotosUI
import SwiftUI
import UIKit

/// Items seen one at a time across the whole screen, the way Photos shows them.
///
/// A sideways swipe goes to the next item, a swipe down closes, and a tap
/// hides or shows the bars, leaving the picture on black.
struct Pager<Item: Identifiable, Page: View, Bar: View>: View where Item.ID == String {
  private let items: [Item]
  private let heading: (Item) -> (title: String, detail: String)
  private let page: (Item, Bool) -> Page
  private let bar: (Item, @escaping () -> Void) -> Bar
  private let info: (Item) -> [Fact]
  @ViewState private var current: String?
  @ViewState private var bars = true
  @ViewState private var drop: CGFloat = 0
  @ViewState private var informing = false
  @Environment(\.dismiss) private var dismiss

  /// - Parameters:
  ///   - items: The items to page through.
  ///   - start: The identifier of the item shown first.
  ///   - heading: The title and the line under it for an item.
  ///   - page: The item's content, told whether it is the one on screen.
  ///   - bar: The actions for the item on screen, given the way to open its info.
  ///   - info: What the info sheet tells about an item.
  init(
    items: [Item],
    start: String,
    heading: @escaping (Item) -> (title: String, detail: String),
    @ViewBuilder page: @escaping (Item, Bool) -> Page,
    @ViewBuilder bar: @escaping (Item, @escaping () -> Void) -> Bar,
    info: @escaping (Item) -> [Fact]
  ) {
    self.items = items
    self.heading = heading
    self.page = page
    self.bar = bar
    self.info = info
    _current = ViewState(initialValue: start)
  }

  var body: some View {
    ZStack {
      (bars ? Color(.systemBackground) : Color.black)
        .opacity(1 - min(drop / 400, 0.6))
        .ignoresSafeArea()
      ScrollView(.horizontal) {
        LazyHStack(spacing: 0) {
          ForEach(items) { item in
            page(item, item.id == current)
              .containerRelativeFrame([.horizontal, .vertical])
              .id(item.id)
          }
        }
        .scrollTargetLayout()
      }
      .scrollTargetBehavior(.paging)
      .scrollPosition(id: $current)
      .scrollIndicators(.hidden)
      .ignoresSafeArea()
      .offset(y: drop)
      .scaleEffect(1 - min(drop / 2000, 0.15))
      .simultaneousGesture(lowering)
      .onTapGesture {
        withAnimation(.easeInOut(duration: 0.2)) {
          bars.toggle()
        }
      }
    }
    .safeAreaInset(edge: .top) {
      if bars, let item = shown {
        top(item)
          .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .safeAreaInset(edge: .bottom) {
      if bars, let item = shown {
        bar(item) {
          informing = true
        }
          .padding(.horizontal, 8)
          .padding(.top, 8)
          .padding(.bottom, 4)
          .frame(maxWidth: .infinity)
          .background(.bar)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .statusBarHidden(!bars)
    .sheet(isPresented: $informing) {
      if let item = shown {
        InfoSheet(title: heading(item).title, facts: info(item))
          .presentationDetents([.medium, .large])
      }
    }
  }

  private var shown: Item? {
    items.first { $0.id == current } ?? items.first
  }

  private func top(_ item: Item) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Button {
        dismiss()
      } label: {
        Image(systemName: "chevron.down")
          .font(.body.weight(.semibold))
          .frame(width: 44, height: 44)
      }
      .accessibilityLabel("Close")
      Spacer(minLength: 0)
      VStack(spacing: 1) {
        Text(heading(item).title)
          .font(.subheadline.weight(.semibold))
        Text(heading(item).detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .lineLimit(1)
      Spacer(minLength: 0)
      // Keeps the title in the middle, across from the close button.
      Color.clear
        .frame(width: 44, height: 44)
    }
    .padding(.horizontal, 6)
    .background(.bar)
  }

  /// A swipe down that takes the picture with the finger and closes past a point.
  private var lowering: some Gesture {
    DragGesture(minimumDistance: 20)
      .onChanged { value in
        guard value.translation.height > abs(value.translation.width) else {
          return
        }
        drop = max(0, value.translation.height)
      }
      .onEnded { value in
        if drop > 120 || value.predictedEndTranslation.height > 400 {
          dismiss()
        } else {
          withAnimation(.snappy) {
            drop = 0
          }
        }
      }
  }
}

/// One line of an item's info: what it is and its value.
struct Fact: Identifiable {
  let name: String
  let value: String

  var id: String {
    name
  }
}

/// What there is to know about an item, as a sheet.
struct InfoSheet: View {
  let title: String
  let facts: [Fact]
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List(facts) { fact in
        LabeledContent(fact.name) {
          Text(fact.value)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
        }
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
  }
}

/// A picture that zooms with two fingers or a double tap, and pans while zoomed.
struct ZoomingPicture: UIViewRepresentable {
  let image: UIImage

  func makeUIView(context: Context) -> UIScrollView {
    let scroll = UIScrollView()
    scroll.minimumZoomScale = 1
    scroll.maximumZoomScale = 5
    scroll.showsHorizontalScrollIndicator = false
    scroll.showsVerticalScrollIndicator = false
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.backgroundColor = .clear
    scroll.delegate = context.coordinator
    let picture = UIImageView(image: image)
    picture.contentMode = .scaleAspectFit
    picture.frame = scroll.bounds
    picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    scroll.addSubview(picture)
    let twice = UITapGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.doubled(_:))
    )
    twice.numberOfTapsRequired = 2
    scroll.addGestureRecognizer(twice)
    context.coordinator.picture = picture
    return scroll
  }

  func updateUIView(_ scroll: UIScrollView, context: Context) {
    context.coordinator.picture?.image = image
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  // UIKit talks to a delegate object, which must be a class.
  final class Coordinator: NSObject, UIScrollViewDelegate {
    var picture: UIImageView?

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
      picture
    }

    @objc func doubled(_ tap: UITapGestureRecognizer) {
      guard let scroll = tap.view as? UIScrollView else {
        return
      }
      if scroll.zoomScale > 1 {
        scroll.setZoomScale(1, animated: true)
      } else {
        let point = tap.location(in: picture)
        let side = scroll.bounds.size.width / 2.5
        scroll.zoom(
          to: CGRect(x: point.x - side / 2, y: point.y - side / 2, width: side, height: side),
          animated: true
        )
      }
    }
  }
}

/// A Live Photo that plays while it is pressed, as in Photos.
struct LivePicture: UIViewRepresentable {
  let photo: PHLivePhoto

  func makeUIView(context: Context) -> PHLivePhotoView {
    let view = PHLivePhotoView()
    view.contentMode = .scaleAspectFit
    view.livePhoto = photo
    return view
  }

  func updateUIView(_ view: PHLivePhotoView, context: Context) {
    view.livePhoto = photo
  }
}

/// The system's video player with its usual controls.
struct Screening: View {
  let player: AVPlayer

  var body: some View {
    VideoPlayer(player: player)
  }
}

/// A row of actions spread evenly across the bottom, each a symbol with a short word, as in Photos.
struct ActionBar<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: 0) {
      content
    }
    .frame(maxWidth: .infinity)
  }
}

/// One action of an action bar.
struct ActionButton: View {
  private let title: String
  private let symbol: String
  private let tint: Color
  private let spoken: String
  private let action: () -> Void
  @Environment(\.isEnabled) private var enabled

  /// - Parameters:
  ///   - title: The short word under the symbol.
  ///   - symbol: The SF Symbol's name.
  ///   - tint: The colour of the symbol and the word.
  ///   - spoken: What VoiceOver says, when the word alone is too short.
  ///   - action: What the button does.
  init(
    _ title: String,
    symbol: String,
    tint: Color = .accentColor,
    spoken: String = "",
    action: @escaping () -> Void
  ) {
    self.title = title
    self.symbol = symbol
    self.tint = tint
    self.spoken = spoken.isEmpty ? title : spoken
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      VStack(spacing: 3) {
        Image(systemName: symbol)
          .font(.system(size: 21, weight: .regular))
          .frame(height: 26)
        Text(title)
          .font(.caption2.weight(.medium))
          .lineLimit(1)
      }
      .foregroundStyle(enabled ? tint : Color.secondary)
      .frame(maxWidth: .infinity, minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(spoken)
  }
}
