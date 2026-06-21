import SwiftUI

/// App-wide font zoom for both the rendered view and the raw editor. A single shared
/// instance so every tab zooms together and the choice survives across launches
/// (persisted in UserDefaults). ⌘+ / ⌘- step it; ⌘0 resets to 1.0.
final class FontScale: ObservableObject {
    static let shared = FontScale()

    private static let key = "glim.fontScale"
    static let minScale = 0.5
    static let maxScale = 3.0
    private static let step = 0.1

    @Published private(set) var scale: Double

    private init() {
        let stored = UserDefaults.standard.double(forKey: Self.key)
        scale = (stored >= Self.minScale && stored <= Self.maxScale) ? stored : 1.0
    }

    private func set(_ value: Double) {
        let clamped = min(Self.maxScale, max(Self.minScale, (value * 100).rounded() / 100))
        guard clamped != scale else { return }
        scale = clamped
        UserDefaults.standard.set(clamped, forKey: Self.key)
    }

    func zoomIn()  { set(scale + Self.step) }
    func zoomOut() { set(scale - Self.step) }
    func reset()   { set(1.0) }
}
