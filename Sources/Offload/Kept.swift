import Foundation
import Observation
import OffloadCore
import Photos
import UIKit
import os

/// What Yandex Disk keeps, as the screen looks through it and brings it back.
@MainActor
@Observable
final class Kept {
  /// What is happening right now, in words for the user.
  private(set) var line = ""
  @ObservationIgnored private let pictures = NSCache<NSString, UIImage>()
  private let archive: any Archive
  private let gallery: any Gallery
  private let survey: Survey
  private let scratch: URL
  private let words: AsyncStream<String>
  private let log = Logger(subsystem: "Offload", category: "kept")

  /// - Parameters:
  ///   - archive: The cloud's kept files.
  ///   - gallery: The photo library originals come back to.
  ///   - survey: The library survey, read again after an original has come back.
  ///   - scratch: Folder that downloads pass through.
  ///   - words: What the network says it is doing, as it does it.
  init(
    archive: any Archive,
    gallery: any Gallery,
    survey: Survey,
    scratch: URL,
    words: AsyncStream<String>
  ) {
    self.archive = archive
    self.gallery = gallery
    self.survey = survey
    self.scratch = scratch
    self.words = words
  }

  /// Starts listening to what the network says, and clears what an earlier run left behind.
  func start() {
    try? FileManager.default.removeItem(at: scratch)
    Task {
      for await word in words {
        line = word
      }
    }
  }

  /// What the folder at the path holds.
  func shelf(_ path: String) async throws -> Shelf {
    try await archive.shelf(path)
  }

  /// The small picture of a file; empty when there is none to be had.
  func thumbnail(of file: KeptFile) async -> [UIImage] {
    if let known = pictures.object(forKey: file.id as NSString) {
      return [known]
    }
    guard let data = try? await archive.thumbnail(of: file), let image = UIImage(data: data) else {
      return []
    }
    pictures.setObject(image, forKey: file.id as NSString)
    return [image]
  }

  /// The large picture of a file; empty when there is none to be had.
  func picture(of file: KeptFile) async -> [UIImage] {
    guard let data = try? await archive.picture(of: file), let image = UIImage(data: data) else {
      return await thumbnail(of: file)
    }
    return [image]
  }

  /// Whether the photo library seems to have the original already.
  ///
  /// The library gives a returned item a new identifier, so the item is
  /// known by its name and the moment it was made.
  func onPhone(_ original: KeptOriginal) -> Bool {
    guard case .ranked(let findings) = survey.stage,
      let made = original.made(in: .current).first
    else {
      return false
    }
    let name = original.name()
    return findings.items.contains {
      $0.name == name && abs($0.created.timeIntervalSince(made)) < 1
    }
  }

  /// Brings an original back into the photo library.
  func restore(_ original: KeptOriginal) async throws {
    line = "Preparing"
    let needed = original.parts().reduce(0) { $0 + $1.file.weight() }
    let free = (try? FileManager.default.temporaryDirectory
      .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage) ?? .max
    guard needed <= free else {
      throw NoRoomToRestore(name: original.name(), needed: needed, free: free)
    }
    log.notice("restoring \(original.name(), privacy: .public), \(needed) bytes")
    do {
      try await Retrieval(
        of: original,
        from: archive,
        into: gallery,
        through: scratch.appendingPathComponent(UUID().uuidString)
      ).make()
    } catch {
      let why = error.localizedDescription
      log.error("\(original.name(), privacy: .public) not restored: \(why, privacy: .public)")
      throw error
    }
    log.notice("restored \(original.name(), privacy: .public)")
    line = ""
    await survey.run()
  }
}

/// The photo library of this device as the place originals come back to.
struct PhotoGallery: Gallery {
  func take(_ parts: [FetchedPart], made: [Date]) async throws {
    try await PHPhotoLibrary.shared().performChanges {
      let request = PHAssetCreationRequest.forAsset()
      for part in parts {
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = part.name
        // Moved rather than copied, so the file never takes its space twice.
        options.shouldMoveFile = true
        let kind: PHAssetResourceType
        switch part.role {
        case .photo:
          kind = .photo
        case .alternatePhoto:
          kind = .alternatePhoto
        case .video:
          kind = .video
        case .pairedVideo:
          kind = .pairedVideo
        }
        request.addResource(with: kind, fileURL: part.file, options: options)
      }
      // Without a date the library reads the one inside the file.
      if let moment = made.first {
        request.creationDate = moment
      }
    }
  }
}

/// The device has too little free space to bring an original back.
struct NoRoomToRestore: LocalizedError {
  private let name: String
  private let needed: Int64
  private let free: Int64

  init(name: String, needed: Int64, free: Int64) {
    self.name = name
    self.needed = needed
    self.free = free
  }

  var errorDescription: String? {
    "\(name) needs \(needed.formatted(.byteCount(style: .file))), but this iPhone has only "
      + "\(free.formatted(.byteCount(style: .file))) free"
  }
}
