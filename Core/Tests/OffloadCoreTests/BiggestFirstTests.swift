import OffloadCore
import Testing

@Suite("Biggest first")
struct BiggestFirstTests {
  private struct Lump: Sized, Equatable {
    let size: Int64
    let local: Int64

    func bytes() -> Int64 {
      size
    }

    func onDevice() -> Int64 {
      local
    }
  }

  @Test("orders things from the biggest to the smallest")
  func order() {
    let lumps = [
      Lump(size: 10, local: 10),
      Lump(size: 300, local: 0),
      Lump(size: 42, local: 42),
    ]

    let ranked = BiggestFirst(lumps).ranked()

    #expect(ranked.map { $0.bytes() } == [300, 42, 10])
  }

  @Test("ranks by full size even when the bytes are not on the device")
  func ranksCloudOnly() {
    let lumps = [Lump(size: 5, local: 5), Lump(size: 900, local: 0)]

    let ranked = BiggestFirst(lumps).ranked()

    #expect(ranked.first == Lump(size: 900, local: 0))
  }

  @Test("adds up the full sizes and, separately, the bytes on the device")
  func totals() {
    let ranking = BiggestFirst([
      Lump(size: 10, local: 10),
      Lump(size: 300, local: 0),
      Lump(size: 42, local: 20),
    ])

    #expect(ranking.total() == 352)
    #expect(ranking.onDevice() == 30)
  }

  @Test("of nothing is empty and weighs nothing")
  func empty() {
    let ranking = BiggestFirst([Lump]())

    #expect(ranking.ranked().isEmpty)
    #expect(ranking.total() == 0)
    #expect(ranking.onDevice() == 0)
  }
}
