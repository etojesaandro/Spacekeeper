import Foundation
import OffloadCore
import Testing

@Suite("Placement of an original's files in the cloud")
struct PlacementTests {
  private let moscow = TimeZone(identifier: "Europe/Moscow")!

  @Test("puts a file into the folder of its year and month, named after the moment")
  func path() {
    let placement = Placement(
      taken: Date(timeIntervalSince1970: 1_741_600_072),
      id: "B504FF1B-1234-5678/L0/001",
      zone: moscow
    )

    #expect(
      placement.path(for: "IMG_0669.MOV") == "2025/03/2025-03-10_12-47-52_B504FF1B_IMG_0669.MOV"
    )
  }

  @Test("counts the month in the given time zone")
  func zone() {
    let newYear = Date(timeIntervalSince1970: 1_735_680_600)

    let east = Placement(taken: newYear, id: "ABCDEFGH", zone: moscow).path(for: "a.jpg")
    let west = Placement(taken: newYear, id: "ABCDEFGH", zone: TimeZone(identifier: "UTC")!)
      .path(for: "a.jpg")

    #expect(east.hasPrefix("2025/01/2025-01-01_00-30-00_"))
    #expect(west.hasPrefix("2024/12/2024-12-31_21-30-00_"))
  }

  @Test("tells apart two files of one original that share a name")
  func marked() {
    let placement = Placement(
      taken: Date(timeIntervalSince1970: 1_741_600_072),
      id: "B504FF1B",
      zone: moscow
    )

    #expect(
      placement.path(for: "FullSizeRender.jpg", marked: "2")
        == "2025/03/2025-03-10_12-47-52_B504FF1B_2_FullSizeRender.jpg"
    )
  }

  @Test("keeps an original of unknown date in a folder of its own")
  func undated() {
    let placement = Placement(taken: .distantPast, id: "B504FF1B", zone: moscow)

    #expect(placement.path(for: "IMG_1.JPG") == "undated/undated_B504FF1B_IMG_1.JPG")
  }
}
