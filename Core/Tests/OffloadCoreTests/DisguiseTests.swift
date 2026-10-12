import OffloadCore
import Testing

@Suite("Disguise of a travelling file")
struct DisguiseTests {
  @Test(
    "leaves common picture formats under their own name",
    arguments: ["IMG_1.JPG", "IMG_1.jpeg", "IMG_1.HEIC", "shot.png", "anim.GIF", "pic.webp"]
  )
  func pictures(name: String) {
    #expect(Disguise().name(for: name) == name)
  }

  @Test(
    "adds a neutral extension to everything else",
    arguments: ["IMG_1.MOV", "clip.mp4", "RAW_1.DNG", "Adjustments.plist", "archive.zip", "noext"]
  )
  func others(name: String) {
    #expect(Disguise().name(for: name) == name + ".offload")
  }

  @Test("judges by the last extension only")
  func lastExtension() {
    #expect(Disguise().name(for: "clip.jpg.mov") == "clip.jpg.mov.offload")
    #expect(Disguise().name(for: "2026-07-15_10-38-06_046E68B7_IMG_0800.HEIC")
      == "2026-07-15_10-38-06_046E68B7_IMG_0800.HEIC")
  }

  @Test("changes nothing when it has no extension to add")
  func none() {
    #expect(Disguise(suffix: "", exempt: []).name(for: "IMG_1.MOV") == "IMG_1.MOV")
  }

  @Test("disguises pictures too when nothing is exempt")
  func noExemptions() {
    #expect(Disguise(suffix: ".x", exempt: []).name(for: "IMG_1.JPG") == "IMG_1.JPG.x")
  }

  @Test("knows a name a file travels under from the file's own name")
  func worn() {
    #expect(Disguise().worn(by: "IMG_1.MOV.offload"))
    #expect(!Disguise().worn(by: "IMG_1.MOV"))
    #expect(!Disguise(suffix: "", exempt: []).worn(by: "IMG_1.MOV"))
  }
}
