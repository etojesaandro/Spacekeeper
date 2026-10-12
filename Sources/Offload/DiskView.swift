import OffloadCore
import SwiftUI

/// One folder of what Yandex Disk keeps: its folders, then its originals.
///
/// It shows what is on the Disk whether or not it is still on this iPhone.
struct DiskView: View {
  private let kept: Kept
  private let path: String
  private let close: () -> Void
  @ViewState private var shelves: [Shelf] = []
  @ViewState private var problem = ""

  /// - Parameters:
  ///   - kept: What Yandex Disk keeps.
  ///   - path: The folder to show, below the app's own folder; "" is the top.
  ///   - close: Called when the user is done looking.
  init(kept: Kept, path: String, close: @escaping () -> Void) {
    self.kept = kept
    self.path = path
    self.close = close
  }

  var body: some View {
    content
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            close()
          }
        }
      }
      .task {
        await load()
      }
  }

  @ViewBuilder private var content: some View {
    if let shelf = shelves.first {
      if shelf.folders().isEmpty, shelf.originals().isEmpty {
        ContentUnavailableView(
          "Nothing here",
          systemImage: "icloud",
          description: Text("What you move to Yandex Disk shows up here.")
        )
      } else {
        List {
          if !shelf.folders().isEmpty {
            Section {
              ForEach(shelf.folders(), id: \.self) { folder in
                NavigationLink {
                  DiskView(kept: kept, path: folder, close: close)
                } label: {
                  Label(name(of: folder), systemImage: "folder")
                }
              }
            }
          }
          if !shelf.originals().isEmpty {
            Section {
              ForEach(shelf.originals()) { original in
                NavigationLink {
                  KeptCloseup(kept: kept, original: original, close: close)
                } label: {
                  KeptRow(kept: kept, original: original)
                }
              }
            } header: {
              Text(
                "\(shelf.originals().count.formatted()) items · "
                  + shelf.originals().reduce(0) { $0 + $1.bytes() }
                  .formatted(.byteCount(style: .file))
              )
            } footer: {
              Text("Tap an item to look at it and bring it back to this iPhone.")
            }
          }
        }
      }
    } else if !problem.isEmpty {
      ContentUnavailableView {
        Label("Could not read Yandex Disk", systemImage: "xmark.icloud")
      } description: {
        Text(problem)
      } actions: {
        Button("Try again") {
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

  private var title: String {
    path.isEmpty ? "On Yandex Disk" : name(of: path)
  }

  /// A folder's name for people: a month folder inside a year reads as the month.
  private func name(of folder: String) -> String {
    let levels = folder.split(separator: "/").map(String.init)
    let names = Calendar.current.standaloneMonthSymbols
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
    } catch {
      problem = error.localizedDescription
    }
  }
}

/// One kept original as a line of a folder.
private struct KeptRow: View {
  let kept: Kept
  let original: KeptOriginal
  @ViewState private var pictures: [UIImage] = []

  var body: some View {
    HStack(spacing: 12) {
      Group {
        if let picture = pictures.first {
          Image(uiImage: picture)
            .resizable()
            .aspectRatio(contentMode: .fill)
        } else {
          Image(systemName: original.video() ? "video" : "photo")
            .foregroundStyle(.tertiary)
        }
      }
      .frame(width: 56, height: 56)
      .background(.quaternary)
      .clipShape(RoundedRectangle(cornerRadius: 6))
      VStack(alignment: .leading, spacing: 2) {
        Text(original.name())
          .font(.subheadline)
          .lineLimit(1)
          .truncationMode(.middle)
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(original.bytes().formatted(.byteCount(style: .file)))
        .font(.subheadline.monospacedDigit())
    }
    .task(id: original.id) {
      pictures = await kept.thumbnail(of: original.leading())
    }
  }

  private var detail: String {
    let kind = original.video() ? "Video" : (original.parts().isEmpty ? "File" : "Photo")
    guard let made = original.made(in: .current).first else {
      return kind
    }
    return "\(kind) · \(made.formatted(date: .abbreviated, time: .omitted))"
  }
}

/// One kept original seen large, with the way to bring it back to this iPhone.
struct KeptCloseup: View {
  /// How far bringing it back has got.
  private enum Stage: Equatable {
    case idle
    case working
    case back
    case failed(String)
  }

  private let kept: Kept
  private let original: KeptOriginal
  private let close: () -> Void
  @ViewState private var pictures: [UIImage] = []
  @ViewState private var looked = false
  @ViewState private var stage = Stage.idle

  /// - Parameters:
  ///   - kept: What Yandex Disk keeps.
  ///   - original: The original to show.
  ///   - close: Called when the user is done looking.
  init(kept: Kept, original: KeptOriginal, close: @escaping () -> Void) {
    self.kept = kept
    self.original = original
    self.close = close
  }

  var body: some View {
    VStack(spacing: 0) {
      Group {
        if let picture = pictures.first {
          Image(uiImage: picture)
            .resizable()
            .scaledToFit()
        } else if looked {
          ContentUnavailableView(
            "No preview",
            systemImage: "eye.slash",
            description: Text("Yandex Disk has no picture of this file.")
          )
        } else {
          ProgressView()
            .tint(.white)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black)
      VStack(alignment: .leading, spacing: 10) {
        Text(detail)
          .font(.subheadline)
        action
      }
      .padding()
    }
    .navigationTitle(original.name())
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(stage == .working)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Done") {
          close()
        }
        .disabled(stage == .working)
      }
    }
    .interactiveDismissDisabled(stage == .working)
    .task {
      pictures = await kept.picture(of: original.leading())
      looked = true
    }
  }

  @ViewBuilder private var action: some View {
    switch stage {
    case .working:
      HStack(spacing: 12) {
        ProgressView()
        Text(kept.line.isEmpty ? "Working" : kept.line)
          .font(.subheadline)
          .monospacedDigit()
      }
      Text("Keep the app open until it finishes.")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .back:
      Label("Back in Photos on this iPhone", systemImage: "checkmark.circle.fill")
        .font(.subheadline.weight(.semibold))
      Text("It stays on Yandex Disk as well.")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .idle, .failed:
      if case .failed(let reason) = stage {
        Label(reason, systemImage: "exclamationmark.triangle")
          .font(.caption)
      }
      if original.parts().isEmpty {
        Text("This is neither a photo nor a video, so Photos cannot take it back.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        if kept.onPhone(original) {
          Label("Photos on this iPhone seems to have it already", systemImage: "iphone")
            .font(.caption)
        }
        Button {
          Task {
            await restore()
          }
        } label: {
          Text(kept.onPhone(original) ? "Restore another copy" : "Restore to this iPhone")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        Text(
          "Downloads it from Yandex Disk, checks the download and adds it to Photos. "
            + "It stays on Yandex Disk as well."
            + (original.count() > original.parts().count
              ? " Edits made in Photos are not brought back: it returns as it was taken."
              : "")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private var detail: String {
    let kind = original.video() ? "Video" : (original.parts().isEmpty ? "File" : "Photo")
    let size = original.bytes().formatted(.byteCount(style: .file))
    let files = original.count() > 1 ? " in \(original.count()) files" : ""
    guard let made = original.made(in: .current).first else {
      return "\(kind) · \(size)\(files)"
    }
    return "\(kind) · \(size)\(files) · \(made.formatted(date: .abbreviated, time: .shortened))"
  }

  private func restore() async {
    stage = .working
    do {
      try await kept.restore(original)
      stage = .back
    } catch {
      stage = .failed(error.localizedDescription)
    }
  }
}
