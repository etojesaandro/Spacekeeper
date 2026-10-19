import SwiftUI

/// SwiftUI's view-local state, under a name the `@State` macro does not take over.
///
/// The iOS 27 SDK turns `@State` into a macro that stores values in `LazyState`,
/// a type that iOS 18 lacks, so an app using `@State` dies at launch there with
/// "Symbol not found". Use `@ViewState` wherever `@State` would go; it is the
/// same property wrapper, reached without the macro.
typealias ViewState = SwiftUI.State
