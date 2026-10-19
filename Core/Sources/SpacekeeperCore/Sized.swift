/// Anything that takes up storage space.
public protocol Sized {
  /// Bytes of its full-quality content, wherever they are kept.
  func bytes() -> Int64

  /// How many of those bytes sit on the device itself.
  func onDevice() -> Int64
}
