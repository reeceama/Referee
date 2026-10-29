import Foundation

// SwiftMath (Packages/SwiftMath, MIT licence) is compiled in with Referee's own sources rather than
// as a Swift package, so the package system's Bundle.module doesn't exist. Its font bundle,
// mathFonts.bundle, is copied into the app's Resources, which is Bundle.main.
extension Bundle {
    static var module: Bundle { .main }
}
