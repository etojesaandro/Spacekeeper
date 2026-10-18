import OffloadCore
import SwiftUI
import UIKit

/// The Cloud tab: what the chosen cloud keeps, by year and month, to look at and bring back.
struct CloudTab: View {
  private let kept: Kept
  private let clouds: Clouds
  private let account: () -> Void

  /// - Parameters:
  ///   - kept: What the chosen cloud keeps.
  ///   - clouds: Which cloud is chosen, and who is signed in.
  ///   - account: Opens the clouds and accounts.
  init(kept: Kept, clouds: Clouds, account: @escaping () -> Void) {
    self.kept = kept
    self.clouds = clouds
    self.account = account
  }

  var body: some View {
    NavigationStack {
      Group {
        if clouds.connected {
          CloudFolder(kept: kept, cloud: clouds.name, path: "")
            // Another cloud or another account keeps other things.
            .id("\(clouds.name)·\(clouds.connected)")
        } else {
          ContentUnavailableView {
            Label("No cloud connected", systemImage: "icloud.slash")
          } description: {
            Text("Connect Yandex Disk or Google Drive to keep originals there and bring them back.")
          } actions: {
            Button("Connect a Cloud", action: account)
              .buttonStyle(.borderedProminent)
          }
        }
      }
      .navigationTitle(clouds.name)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          AccountButton(clouds: clouds, open: account)
        }
      }
    }
  }
}

/// One folder of the cloud: its year or month folders as cards, then its originals as pictures.
struct CloudFolder: View {
  private let kept: Kept
  private let cloud: String
  private let path: String
  @ViewState private var shelves: [Shelf] = []
  @ViewState private var problem = ""
  @ViewState private var viewing: [String] = []

  /// - Parameters:
  ///   - kept: What the cloud keeps.
  ///   - cloud: The cloud's name.
  ///   - path: The folder to show, below the app's own folder; "" is the top.
  init(kept: Kept, cloud: String, path: String) {
    self.kept = kept
    self.cloud = cloud
    self.path = path
  }

  var body: some View {
    content
      .navigationTitle(path.isEmpty ? cloud : name(of: path))
      .navigationBarTitleDisplayMode(path.isEmpty ? .large : .inline)
      .task {
        await load()
      }
      .refreshable {
        await load()
      }
      .fullScreenCover(
        isPresented: Binding(get: { !viewing.isEmpty }, set: { _ in viewing = [] })
      ) {
        if let shelf = shelves.first, let start = viewing.first {
          CloudViewer(kept: kept, cloud: cloud, originals: shelf.originals(), start: start)
        }
      }
  }

  @ViewBuilder private var content: some View {
    if let shelf = shelves.first {
      if shelf.folders().isEmpty, shelf.originals().isEmpty {
        ContentUnavailableView(
          "Nothing here yet",
          systemImage: "icloud",
          description: Text("What you move or copy to \(cloud) shows up here.")
        )
      } else {
        GeometryReader { frame in
          ScrollView {
            VStack(alignment: .leading, spacing: 16) {
              if !shelf.folders().isEmpty {
                folders(shelf.folders(), width: frame.size.width)
              }
              if !shelf.originals().isEmpty {
                originals(shelf.originals(), width: frame.size.width)
              }
            }
            .padding(.bottom, 16)
          }
        }
      }
    } else if !problem.isEmpty {
      ContentUnavailableView {
        Label("Could not read \(cloud)", systemImage: "exclamationmark.icloud")
      } description: {
        Text(problem)
      } actions: {
        Button("Try Again") {
          problem = ""
          Task {
            await load()
          }
        }
      }
    } else {
      ProgressView()
    }
  }

  private func folders(_ folders: [String], width: CGFloat) -> some View {
    let side = ((width - 16 * 3) / 2).rounded(.down)
    return LazyVGrid(columns: [GridItem(.fixed(side), spacing: 16), GridItem(.fixed(side))], spacing: 16) {
      ForEach(folders, id: \.self) { folder in
        NavigationLink {
          CloudFolder(kept: kept, cloud: cloud, path: folder)
        } label: {
          HStack(spacing: 12) {
            Image(systemName: "folder.fill")
              .font(.title2)
              .foregroundStyle(.tint)
            Text(name(of: folder))
              .font(.headline)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
              .font(.footnote.weight(.semibold))
              .foregroundStyle(.tertiary)
          }
          .padding(14)
          .frame(width: side)
          .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 16)
  }

  private func originals(_ originals: [KeptOriginal], width: CGFloat) -> some View {
    let side = ((width - 2 * 2) / 3).rounded(.down)
    return VStack(alignment: .leading, spacing: 8) {
      Text(
        "\(originals.count.formatted()) items · "
          + originals.reduce(0) { $0 + $1.bytes() }.formatted(.byteCount(style: .file))
      )
      .font(.subheadline.weight(.semibold))
      .padding(.horizontal, 16)
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 2), count: 3), spacing: 2) {
        ForEach(originals) { original in
          CloudCell(kept: kept, original: original, side: side, home: kept.onPhone(original))
            .onTapGesture {
              viewing = [original.id]
            }
        }
      }
    }
  }

  /// A folder's name for people: a month folder inside a year reads as the month.
  private func name(of folder: String) -> String {
    let levels = folder.split(separator: "/").map(String.init)
    let names = Calendar.current.monthSymbols
    if levels.count == 2, levels[0].count == 4, let month = Int(levels[1]),
      names.indices.contains(month - 1)
    {
      return "\(names[month - 1]) \(levels[0])"
    }
    return levels.last ?? folder
  }

  private func load() async {
    do {
      shelves = [try await kept.shelf(path)]
      problem = ""
    } catch {
      problem = error.localizedDescription
    }
  }
}

/// One kept original as a square picture, with its size, and whether the iPhone has it.
private struct CloudCell: View {
  let kept: Kept
  let original: KeptOriginal
  let side: CGFloat
  let home: Bool
  @ViewState private var pictures: [UIImage] = []

  var body: some View {
    Color(.secondarySystemFill)
      .overlay {
        if let picture = pictures.first {
          Image(uiImage: picture)
            .resizable()
            .scaledToFill()
        } else {
          Image(systemName: original.video() ? "video" : "photo")
            .foregroundStyle(.tertiary)
        }
      }
      .frame(width: side, height: side)
      .clipped()
      .overlay(alignment: .bottom) {
        LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
          .frame(height: min(side * 0.45, 36))
      }
      .overlay(alignment: .bottomLeading) {
        Text(original.bytes().formatted(.byteCount(style: .file)))
          .font(.caption2.weight(.semibold).monospacedDigit())
          .foregroundStyle(.white)
          .padding(.horizontal, 4)
          .padding(.bottom, 3)
      }
      .overlay(alignment: .topTrailing) {
        if home {
          Image(systemName: "iphone")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(4)
        }
      }
      .contentShape(Rectangle())
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "\(original.video() ? "Video" : "Photo"), "
          + original.bytes().formatted(.byteCount(style: .file))
          + (home ? ", also on this iPhone" : "")
      )
      .accessibilityAddTraits(.isButton)
      .task(id: original.id) {
        pictures = await kept.thumbnail(of: original.leading())
      }
  }
}

/// Kept originals looked through one by one, each with the way to bring it back.
struct CloudViewer: View {
  /// How far bringing an original back has got.
  private enum Stage: Equatable {
    case working
    case back
    case failed(String)
  }

  private let kept: Kept
  private let cloud: String
  private let originals: [KeptOriginal]
  private let start: String
  @ViewState private var stages: [String: Stage] = [:]

  init(kept: Kept, cloud: String, originals: [KeptOriginal], start: String) {
    self.kept = kept
    self.cloud = cloud
    self.originals = originals
    self.start = start
  }

  var body: some View {
    Pager(
      items: originals,
      start: start,
      heading: { original in
        (
          original.made(in: .current).first?.formatted(date: .abbreviated, time: .omitted)
            ?? original.name(),
          original.bytes().formatted(.byteCount(style: .file))
        )
      },
      page: { original, _ in
        CloudPage(kept: kept, original: original)
      },
      bar: { original in
        actions(for: original)
      },
      info: facts
    )
    .interactiveDismissDisabled(stages.values.contains(.working))
  }

  @ViewBuilder private func actions(for original: KeptOriginal) -> some View {
    switch stages[original.id] {
    case .working:
      HStack(spacing: 12) {
        ProgressView()
        Text(kept.line.isEmpty ? "Bringing it back" : kept.line)
          .font(.subheadline.monospacedDigit())
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, minHeight: 44)
    case .back:
      Label("Back in Photos", systemImage: "checkmark.circle.fill")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.green)
        .frame(maxWidth: .infinity, minHeight: 44)
    case .failed(let reason):
      VStack(spacing: 8) {
        Label(reason, systemImage: "exclamationmark.triangle.fill")
          .font(.footnote)
          .foregroundStyle(.orange)
        restore(original)
      }
    case nil:
      if original.parts().isEmpty {
        Text("Photos can take back only photos and videos.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 44)
      } else {
        restore(original)
      }
    }
  }

  private func restore(_ original: KeptOriginal) -> some View {
    Button {
      Task {
        stages[original.id] = .working
        do {
          try await kept.restore(original)
          stages[original.id] = .back
        } catch {
          stages[original.id] = .failed(error.localizedDescription)
        }
      }
    } label: {
      Label(
        kept.onPhone(original) ? "Restore Another Copy" : "Restore to iPhone",
        systemImage: "square.and.arrow.down"
      )
      .frame(maxWidth: .infinity, minHeight: 30)
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
  }

  private func facts(_ original: KeptOriginal) -> [Fact] {
    var facts = [
      Fact(name: "Kind", value: original.video() ? "Video" : (original.parts().isEmpty ? "File" : "Photo")),
      Fact(name: "File", value: original.name()),
      Fact(name: "Size", value: original.bytes().formatted(.byteCount(style: .file))),
      Fact(name: "Kept on", value: cloud),
      Fact(name: "On this iPhone", value: kept.onPhone(original) ? "Seems so" : "No"),
    ]
    if let made = original.made(in: .current).first {
      facts.insert(Fact(name: "Taken", value: made.formatted(date: .long, time: .shortened)), at: 2)
    }
    if original.count() > 1 {
      facts.append(Fact(name: "Files", value: "\(original.count())"))
    }
    if original.count() > original.parts().count {
      facts.append(Fact(name: "Edits", value: "Not brought back; it returns as it was taken"))
    }
    return facts
  }
}

/// One kept original filling the screen, at the size the cloud draws it.
private struct CloudPage: View {
  let kept: Kept
  let original: KeptOriginal
  @ViewState private var pictures: [UIImage] = []
  @ViewState private var looked = false

  var body: some View {
    Group {
      if let picture = pictures.first {
        ZoomingPicture(image: picture)
      } else if looked {
        ContentUnavailableView(
          "No preview",
          systemImage: "eye.slash",
          description: Text("The cloud has no picture of this file.")
        )
      } else {
        ProgressView()
      }
    }
    .task {
      // The small picture is at hand at once; the large one follows.
      pictures = await kept.thumbnail(of: original.leading())
      let large = await kept.picture(of: original.leading())
      if !large.isEmpty {
        pictures = large
      }
      looked = true
    }
  }
}
